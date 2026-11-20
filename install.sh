#!/usr/bin/env bash
# addipv6 管理脚本：装、更新、卸载、日常维护都在这儿
#
set -uo pipefail

REPO="TianWen6654/addipv6"
BIN=/usr/local/bin/addipv6
UNIT=/etc/systemd/system/addipv6.service
RESTORE_UNIT=/etc/systemd/system/addipv6-restore.service
CONF_DIR=/etc/addipv6
STATE_DIR=/var/lib/addipv6
DEFAULT_PORT=8688
TUNNEL_IFACE=addipv6-wg
TUNNEL_SERVICE=addipv6-tunnel.service
TUNNEL_UNIT=/etc/systemd/system/$TUNNEL_SERVICE
TUNNEL_CONF=$CONF_DIR/$TUNNEL_IFACE.conf
SSH_TUN=tun64
SSH_LINK_SERVICE=addipv6-tun-link.service
SSH_LINK_UNIT=/etc/systemd/system/$SSH_LINK_SERVICE
SSH_DIR=$CONF_DIR/tunnel-ssh

R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; D='\033[2m'; N='\033[0m'

# 下载用的临时目录。用全局变量配脚本级 trap，别用函数级 trap RETURN,
# 那个会在 local 变量销毁之后才触发，set -u 下直接报未绑定。
TMPDIR_DL=""
cleanup() { [ -n "${TMPDIR_DL:-}" ] && rm -rf "$TMPDIR_DL"; TMPDIR_DL=""; return 0; }
trap cleanup EXIT
ok()   { printf "${G}✓${N} %s\n" "$*"; }
warn() { printf "${Y}!${N} %s\n" "$*"; }
err()  { printf "${R}✗${N} %s\n" "$*"; }
info() { printf "  %s\n" "$*"; }
hr()   { printf "${D}%s${N}\n" "────────────────────────────────────────"; }
SELF="sudo bash addipv6-install.sh"

need_root() {
  [ "$(id -u)" -eq 0 ] || { err "要用 root 跑，前面加个 sudo"; exit 1; }
}
need_linux() {
  [ "$(uname -s)" = "Linux" ] || { err "这工具只能跑在 Linux 上"; exit 1; }
}

need_systemd() {
  need_linux
  command -v systemctl >/dev/null && [ -d /run/systemd/system ] || {
    err "安装脚本需要运行中的 systemd，请在 Linux 主机上运行"
    return 1
  }
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv6l)  echo arm ;;
    i386|i686)      echo 386 ;;
    riscv64)        echo riscv64 ;;
    *) return 1 ;;
  esac
}

installed() { [ -x "$BIN" ]; }

current_port() {
  local port
  port=$(sed -nE '/^ExecStart=/s/.*[[:space:]]-listen[= ][^[:space:]]*:([0-9]+).*/\1/p' "$UNIT" 2>/dev/null)
  printf '%s\n' "${port:-$DEFAULT_PORT}"
}

server_host() {
  local host
  host=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null) || host=""
  if [ -z "$host" ]; then
    host=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  [[ "$host" == *:* ]] && host="[$host]"
  printf '%s\n' "${host:-服务器IP}"
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ] || {
    err "端口必须是 1 到 65535 之间的整数"
    return 1
  }
}

restart_service() {
  systemctl restart addipv6 && sleep 1 && systemctl is-active --quiet addipv6
}

write_unit() {
  local port="$1"
  cat > "$UNIT" <<EOF || return 1
[Unit]
Description=addipv6 web
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -listen 0.0.0.0:${port}
Restart=on-failure
RestartSec=3s
# 改网卡地址要这个能力，其它权限一概不给。
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
}

prepare_download_dir() {
  cleanup
  TMPDIR_DL=$(mktemp -d)
}

bundle_dist() {
  local dir
  dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
  [ -f "$dir/dist/SHA256SUMS" ] || return 1
  printf '%s\n' "$dir/dist"
}

stage_bundle_binary() {
  local dir="$1" arch asset checksum
  arch=$(detect_arch) || { err "认不出这个 CPU 架构：$(uname -m)"; return 1; }
  asset="addipv6-linux-${arch}"
  checksum=$(awk -v asset="$asset" '$2 == asset {print $1; exit}' "$dir/SHA256SUMS")
  if [[ ! "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || ! prepare_download_dir ||
     ! install -m 755 "$dir/$asset" "$TMPDIR_DL/addipv6" ||
     ! (cd "$TMPDIR_DL" && printf '%s  addipv6\n' "$checksum" | sha256sum --check --status); then
    err "离线包缺少 ${arch} 二进制或 SHA-256 校验失败"
    return 1
  fi
}

# 先用离线包或 Releases；在线下载失败时回退到源码编译。
fetch_binary() {
  local arch url tmp asset checksum bundled
  if bundled=$(bundle_dist); then
    stage_bundle_binary "$bundled"
    return
  fi
  arch=$(detect_arch) || { err "认不出这个 CPU 架构：$(uname -m)"; return 1; }
  prepare_download_dir || return 1
  tmp="$TMPDIR_DL"
  asset="addipv6-linux-${arch}"
  url="https://github.com/${REPO}/releases/latest/download"

  info "架构 ${arch}，从 Releases 下载"
  if curl -fsSL --retry 2 --max-time 25 -o "$tmp/SHA256SUMS" "$url/SHA256SUMS"; then
    checksum=$(awk -v asset="$asset" '$2 == asset {print $1; exit}' "$tmp/SHA256SUMS")
    if [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] &&
       curl -fsSL --retry 2 --max-time 180 -o "$tmp/addipv6" "$url/$asset" &&
       (cd "$tmp" && printf '%s  addipv6\n' "$checksum" | sha256sum --check --status); then
      return 0
    fi
    warn "下载或校验失败"
  fi

  warn "Releases 下不动，改用源码编译"
  if ! command -v go >/dev/null 2>&1; then
    err "没装 Go，编译不了"
    info "要么等 Releases 恢复，要么先装 Go："
    info "  apt install -y golang   # 或者去 https://go.dev/dl 拿新版"
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    err "没装 git，拉不了源码。先 apt install -y git"
    return 1
  fi
  git clone --depth 1 "https://github.com/${REPO}.git" "$tmp/src" >/dev/null 2>&1 || {
    err "源码拉取失败，检查下网络"; return 1
  }
  ( cd "$tmp/src" && version=$(git rev-parse --short HEAD) &&
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$tmp/addipv6" . ) || {
    err "编译失败"; return 1
  }
}

deploy_binary() {
  local new_install="$1" port="$2" staged was_active=0
  if [ "$new_install" = no ]; then
    cp -p "$BIN" "$TMPDIR_DL/previous" || return 1
    if systemctl is-active --quiet addipv6; then was_active=1; fi
  fi
  staged=$(mktemp "${BIN}.XXXXXX") || return 1
  if ! install -m 755 "$TMPDIR_DL/addipv6" "$staged" || ! mv -f "$staged" "$BIN"; then
    rm -f "$staged"
    return 1
  fi

  if [ "$new_install" = yes ]; then
    if write_unit "$port" && systemctl daemon-reload &&
       systemctl enable addipv6 && restart_service; then
      return 0
    fi
    systemctl disable --now addipv6 >/dev/null 2>&1
    rm -f "$BIN" "$UNIT"
    systemctl daemon-reload
  elif restart_service; then
    return 0
  else
    if ! install -m 755 "$TMPDIR_DL/previous" "$staged" || ! mv -f "$staged" "$BIN"; then
      err "无法恢复旧程序，请检查 $BIN"
      rm -f "$staged"
      return 1
    fi
    if [ "$was_active" -eq 1 ]; then
      restart_service || err "无法重启旧版本"
    else
      systemctl stop addipv6 || err "无法恢复服务的停止状态"
    fi
  fi
  err "服务启动失败，已尝试回滚。查看日志：journalctl -u addipv6 -n 30 --no-pager"
  return 1
}

do_install() {
  need_root; need_systemd || return 1
  local port="${1:-$DEFAULT_PORT}"
  valid_port "$port" || return 1

  if installed; then
    if [ -n "${1:-}" ] && [ "$port" != "$(current_port)" ]; then
      err "已安装。请用 port $port 修改端口"
      return 1
    fi
    if ! systemctl is-active --quiet addipv6; then restart_service || return 1; fi
    do_status
    return
  fi
  if [ -e "$UNIT" ] || [ -e "$BIN" ]; then
    err "检测到不完整的安装，请先运行 uninstall 再安装"
    return 1
  fi

  fetch_binary || return 1
  install -d -m 700 "$CONF_DIR" || return 1
  deploy_binary yes "$port" || return 1

  hr
  ok "装好了：$($BIN version)"
  show_access "$port"
  hr
  info "有防火墙记得放行 ${port}"
  info "查看状态：${SELF} status"
}

show_access() {
  local port="${1:-$(current_port)}"
  local pw
  pw=$(cat "$CONF_DIR/password" 2>/dev/null || echo "(看 journalctl -u addipv6)")
  printf "  打开  ${B}http://%s:%s${N}\n" "$(server_host)" "$port"
  printf "  密码  ${B}%s${N}\n" "$pw"
}

do_update() {
  need_root; need_systemd || return 1
  installed || { err "还没装过，先选安装"; return 1; }
  fetch_binary || return 1
  if cmp -s "$TMPDIR_DL/addipv6" "$BIN"; then
    ok "已经是最新版本"
    return 0
  fi
  deploy_binary no "" || return 1
  ok "更新完成：$($BIN version 2>/dev/null)"
  info "地址记录和 Cloudflare 配置都没动"
}

do_uninstall() {
  need_root; need_systemd || return 1
  local purge="${1:-}"
  if [ -f "$UNIT" ]; then systemctl disable --now addipv6 || return 1; fi
  if [ -f "$RESTORE_UNIT" ]; then systemctl disable --now addipv6-restore || return 1; fi
  if [ -f "$TUNNEL_UNIT" ] || [ -f "$TUNNEL_CONF" ] || [ -d "$SSH_DIR" ]; then remove_tunnel || return 1; fi
  rm -f "$UNIT" "$RESTORE_UNIT" "$BIN" || return 1
  systemctl daemon-reload || return 1
  ok "程序和服务都删了"

  if [ "$purge" = "purge" ]; then
    rm -rf "$CONF_DIR" "$STATE_DIR" || return 1
    ok "配置和地址记录也清了"
    warn "已经加到网卡上的 IPv6 还在，重启后会自己消失"
  else
    info "配置还留着：$CONF_DIR 和 $STATE_DIR"
    info "要一起清掉就跑：${SELF} uninstall purge"
  fi
}

tunnel_status() {
  local iface=$TUNNEL_IFACE
  if [ ! -f "$TUNNEL_UNIT" ]; then
    info "尚未配置公网 IPv6 隧道"
    return 0
  fi
  if ! systemctl is-active --quiet "$TUNNEL_SERVICE"; then
    err "隧道未运行：journalctl -u $TUNNEL_SERVICE -n 30 --no-pager"
    return 1
  fi
  if grep -Fxq '# Transport: ssh' "$TUNNEL_UNIT"; then iface=$SSH_TUN; fi
  ip -6 -br addr show dev "$iface" && ip -6 route show dev "$iface"
}

tunnel_check() {
  local iface=$TUNNEL_IFACE
  [ -f "$TUNNEL_UNIT" ] && tunnel_status || { err "请先启用隧道"; return 1; }
  if grep -Fxq '# Role: relay' "$TUNNEL_UNIT"; then
    err "请在 IPv4 客户端运行 tunnel check"
    return 1
  fi
  if grep -Fxq '# Transport: ssh' "$TUNNEL_UNIT"; then iface=$SSH_TUN; fi
  command -v ping >/dev/null || { err "请安装支持 IPv6 的 ping"; return 1; }
  if ping -6 -I "$iface" -c 2 -W 3 2606:4700:4700::1111; then
    ok "隧道 IPv6 出站测试通过"
  else
    err "IPv6 探测无响应。检查对端连接、路由前缀和 IPv6 防火墙"
    return 1
  fi
}

remove_tunnel() {
  local file
  for file in "$TUNNEL_UNIT" "$SSH_LINK_UNIT" "$TUNNEL_CONF" "$SSH_DIR/linkctl"; do
    if [ -f "$file" ] && ! grep -Fxq '# Managed by addipv6' "$file"; then
      err "发现同名的其他文件：$file"
      return 1
    fi
  done
  if [ -f "$TUNNEL_UNIT" ]; then
    systemctl disable --now "$TUNNEL_SERVICE" || return 1
  fi
  if [ -f "$SSH_LINK_UNIT" ]; then systemctl stop "$SSH_LINK_SERVICE" || return 1; fi
  if [ -d "$SSH_DIR" ]; then
    [ -f "$SSH_DIR/linkctl" ] || { err "请检查残留目录 $SSH_DIR"; return 1; }
    rm -f "$SSH_DIR"/{client.conf,identity,known_hosts,linkctl,relays} && rmdir "$SSH_DIR" || return 1
  fi
  rm -f "$TUNNEL_UNIT" "$SSH_LINK_UNIT" "$TUNNEL_CONF" && systemctl daemon-reload || return 1
  ok "隧道已移除；已登记的 IPv6 地址仍可在恢复同一前缀后使用"
}

setup_tunnel() {
  local config="$1" prefix="$2" staged quick
  command -v ip >/dev/null && command -v wg >/dev/null && quick=$(command -v wg-quick) || {
    err "需要 iproute2 和 wireguard-tools（Debian/Ubuntu：apt install iproute2 wireguard-tools）"
    return 1
  }
  ensure_tunnel_binary tunnel-config || return 1
  cleanup
  TMPDIR_DL=$(mktemp -d) || return 1
  staged="$TMPDIR_DL/$TUNNEL_IFACE.conf"
  if ! (umask 077; "$BIN" tunnel-config "$config" "$prefix" > "$staged"); then
    err "导入失败。请检查配置，或先用 update 升级 addipv6"
    return 1
  fi
  if [ -e "$TUNNEL_UNIT" ] || [ -e "$TUNNEL_CONF" ]; then
    if ! grep -Fxq '# Managed by addipv6' "$TUNNEL_UNIT" 2>/dev/null || ! cmp -s "$staged" "$TUNNEL_CONF"; then
      err "已有不同的隧道配置。更换前请先运行 tunnel remove"
      return 1
    fi
    systemctl enable --now "$TUNNEL_SERVICE" && tunnel_status
    return
  fi
  if [ -e "$SSH_LINK_UNIT" ] || [ -e "$SSH_DIR" ]; then
    err "检测到 SSH 隧道配置，请先运行 tunnel remove"
    return 1
  fi
  if ip link show dev "$TUNNEL_IFACE" >/dev/null 2>&1; then
    err "网卡 $TUNNEL_IFACE 已存在，请检查现有隧道"
    return 1
  fi
  cat > "$TMPDIR_DL/tunnel.service" <<EOF || return 1
# Managed by addipv6
[Unit]
Description=addipv6 routed WireGuard IPv6 tunnel
Wants=network-online.target
After=network-online.target
Before=addipv6.service addipv6-restore.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$quick up $TUNNEL_CONF
ExecStop=$quick down $TUNNEL_CONF
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=4

[Install]
WantedBy=multi-user.target
EOF
  if ! install -d -m 700 "$CONF_DIR" || ! install -m 600 "$staged" "$TUNNEL_CONF" ||
     ! install -m 644 "$TMPDIR_DL/tunnel.service" "$TUNNEL_UNIT" ||
     ! systemctl daemon-reload || ! systemctl enable --now "$TUNNEL_SERVICE"; then
    if [ -f "$TUNNEL_UNIT" ]; then systemctl disable --now "$TUNNEL_SERVICE" >/dev/null 2>&1; fi
    rm -f "$TUNNEL_UNIT" "$TUNNEL_CONF"
    systemctl daemon-reload
    err "隧道启动失败。查看日志：journalctl -u $TUNNEL_SERVICE -n 30 --no-pager"
    return 1
  fi
  ok "隧道已配置并启用开机启动。刷新网页后选择 $TUNNEL_IFACE 批量加址"
  info "检测出站：${SELF} tunnel check"
  tunnel_status
}

tunnel_usage() {
  printf '用法：%s tunnel setup <WireGuard 配置文件> <公网路由前缀>\n' "$SELF"
  printf '      %s tunnel {auto|ssh-setup} <用户@中继> <TCP端口> <公网/64> <私钥> <known_hosts> [用户@备用中继:端口 ...]\n' "$SELF"
  printf '      %s tunnel ssh-relay <中继SSH用户> <公网/64>\n' "$SELF"
  printf '      %s tunnel {detect|status|check|remove}\n' "$SELF"
}

require_bin_command() {
  local bundled
  CLI_BIN="$BIN"
  if bundled=$(bundle_dist); then
    stage_bundle_binary "$bundled" || return 1
    CLI_BIN="$TMPDIR_DL/addipv6"
  fi
  if ! binary_supports "$CLI_BIN" "$1"; then
    err "请先安装或更新 addipv6，再运行 $1"
    return 1
  fi
}

binary_supports() {
  [ -x "$1" ] && "$1" --help | grep -Fq "  addipv6 $2 "
}

ensure_tunnel_binary() {
  local command="$1"
  if binary_supports "$BIN" "$command"; then return 0; fi
  if installed; then
    if ! bundle_dist >/dev/null; then
      err "已安装的版本缺少 $command，请先运行 update"
      return 1
    fi
    do_update || return 1
  else
    do_install || return 1
  fi
  binary_supports "$BIN" "$command" || { err "安装的二进制仍缺少 $command"; return 1; }
}

do_cloudflare_web() {
  local hostname="$1" origin=""
  shift
  if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then origin="$1"; shift; fi
  require_bin_command cloudflare-web || return 1
  if [ -z "$origin" ]; then
    origin=$(curl -4 --noproxy '*' -fsS --max-time 6 https://api.ipify.org) || {
      err "无法检测公网 IPv4，请显式提供源站 IPv4"
      return 1
    }
  fi
  "$CLI_BIN" cloudflare-web "$CONF_DIR" "$hostname" "$origin" "$@"
}

tunnel_detect() {
  local route target found=0
  command -v ip >/dev/null || { err "需要 iproute2"; return 3; }
  for target in 2606:4700:4700::1111 2001:4860:4860::8888; do
    route=$(ip -6 -o route get "$target" 2>/dev/null) || continue
    found=1
    if command -v timeout >/dev/null && timeout 3 bash -c 'exec 3<>/dev/tcp/$1/443' _ "$target" 2>/dev/null; then
      ok "公网 IPv6 TCP 443 可达"
      info "$route"
      return 0
    fi
  done
  if [ "$found" -eq 1 ] || [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
    warn "已有 IPv6 路由，公网 TCP 443 探测未通过"
    return 3
  fi
  if route=$(ip -4 -o route get 1.1.1.1 2>/dev/null); then
    info "有 IPv4 路由，未发现公网 IPv6 路由"
    info "$route"
    return 2
  fi
  err "没有可用的 IPv4 出站路由"
  return 3
}

tunnel_auto() {
  local result=0
  tunnel_detect || result=$?
  case "$result" in
    0) info "当前可直接使用 IPv6" ;;
    2) setup_ssh_client "$@" ;;
    *) err "无法确认当前网络适合自动接管。可用 tunnel ssh-setup 手动启用隧道"; return 1 ;;
  esac
}

prepare_ssh_tunnel() {
  command -v ip >/dev/null && [ -c /dev/net/tun ] || { err "需要 iproute2 和 /dev/net/tun"; return 1; }
  if [ -e "$TUNNEL_UNIT" ] || [ -e "$TUNNEL_CONF" ] || [ -e "$SSH_LINK_UNIT" ] || [ -e "$SSH_DIR" ]; then
    err "已存在隧道配置。切换前请运行 tunnel remove"
    return 1
  fi
  if ip link show dev "$SSH_TUN" >/dev/null 2>&1; then
    err "网卡 $SSH_TUN 已存在"
    return 1
  fi
  cleanup
  TMPDIR_DL=$(mktemp -d) || return 1
  cat > "$TMPDIR_DL/linkctl" <<'EOF'
#!/bin/bash
# Managed by addipv6
set -euo pipefail
iface=tun64
alias=addipv6-ssh-tun
if [ "$1" = down ]; then
  if ip -d -o link show dev "$iface" 2>/dev/null | grep -Eq " alias $alias( |$)"; then
    ip link del dev "$iface"
  fi
  exit
fi
role=$2
route=$3
owner=()
if [ "$role" = relay ]; then owner=(user "$4"); fi
ip tuntap add dev "$iface" mode tun "${owner[@]}"
trap 'ip link del dev "$iface"' EXIT
ip link set dev "$iface" alias "$alias"
ip link set dev "$iface" mtu 1400 up
if [ "$role" = relay ]; then
  ip -6 route add "$route" dev "$iface"
else
  ip -6 addr add "$route" dev "$iface" nodad
  ip -6 route add default dev "$iface" src "${route%/*}" metric 4096
fi
trap - EXIT
EOF
}

write_ssh_link_unit() {
  local output="$1" role="$2" route="$3" account="${4:-}"
  cat > "$output" <<EOF
# Managed by addipv6
# Transport: ssh
# Role: $role
[Unit]
Description=addipv6 SSH TUN interface ($role)
Wants=network-online.target
After=network-online.target
Before=addipv6.service addipv6-restore.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SSH_DIR/linkctl up $role $route $account
ExecStop=$SSH_DIR/linkctl down

[Install]
WantedBy=multi-user.target
EOF
}

activate_ssh_tunnel() {
  if install -m 644 "$TMPDIR_DL/tunnel.service" "$TUNNEL_UNIT" &&
     systemctl daemon-reload && systemctl enable --now "$TUNNEL_SERVICE"; then
    tunnel_status
    return
  fi
  remove_tunnel
  err "SSH TUN 启动失败。查看日志：journalctl -u $TUNNEL_SERVICE -u $SSH_LINK_SERVICE -n 40 --no-pager"
  return 1
}

setup_ssh_client() {
  local target="$1" port="$2" prefix="$3" key="$4" known="$5"
  local account="${target%@*}" host="${target#*@}" addr lookup sshpath endpoint relay_host relay_port
  shift 5
  local relays=("$target:$port" "$@")
  [ "${#relays[@]}" -le 16 ] || { err "最多配置 16 个端点"; return 1; }
  if [[ "$target" != *@* || ! "$account" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ || ! "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ || "$prefix" != */64 ]]; then
    tunnel_usage; return 1
  fi
  valid_port "$port" || return 1
  sshpath=$(command -v ssh) && command -v ssh-keygen >/dev/null || { err "需要 openssh-client"; return 1; }
  command -v ping >/dev/null || { err "需要支持 IPv6 的 ping，用于中继健康检测"; return 1; }
  for endpoint in "${relays[@]}"; do
    if [[ ! "$endpoint" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*@([a-zA-Z0-9][a-zA-Z0-9.-]*):([1-9][0-9]{0,4})$ ]]; then
      err "中继格式须为用户@地址:端口"; return 1
    fi
    relay_host=${BASH_REMATCH[1]}; relay_port=${BASH_REMATCH[2]}
    valid_port "$relay_port" || return 1
    lookup="$relay_host"
    if [ "$relay_port" != 22 ]; then lookup="[$relay_host]:$relay_port"; fi
    ssh-keygen -F "$lookup" -f "$known" >/dev/null || { err "known_hosts 中没有已验证的 $lookup"; return 1; }
  done
  prepare_ssh_tunnel || return 1
  if ! binary_supports "$BIN" tunnel-supervise; then
    ensure_tunnel_binary tunnel-supervise && prepare_ssh_tunnel || return 1
  fi
  addr=$("$BIN" tunnel-address "$prefix") || { err "请检查前缀，或先更新 addipv6"; return 1; }
  # Stage credentials privately before creating any service files.
  install -m 600 -- "$key" "$TMPDIR_DL/identity" && install -m 600 -- "$known" "$TMPDIR_DL/known_hosts" || return 1
  printf '%s\n' "${relays[@]}" > "$TMPDIR_DL/relays" || return 1
  ssh-keygen -y -P '' -f "$TMPDIR_DL/identity" >/dev/null || { err "需要专用的无口令 SSH 私钥，供系统服务自动重连"; return 1; }
  cat > "$TMPDIR_DL/client.conf" <<EOF || return 1
Host addipv6-relay
    HostName $host
    User $account
    Port $port
    AddressFamily inet
    Tunnel point-to-point
    TunnelDevice 64:64
    IdentityFile $SSH_DIR/identity
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile $SSH_DIR/known_hosts
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
EOF
  write_ssh_link_unit "$TMPDIR_DL/link.service" client "$addr" || return 1
  cat > "$TMPDIR_DL/tunnel.service" <<EOF || return 1
# Managed by addipv6
# Transport: ssh
# Role: client
[Unit]
Description=addipv6 routed IPv6 over SSH TCP
Requires=$SSH_LINK_SERVICE
After=$SSH_LINK_SERVICE
Before=addipv6.service addipv6-restore.service

[Service]
Type=exec
ExecStart=$BIN tunnel-supervise $sshpath $SSH_DIR/client.conf $SSH_DIR/relays
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  install -d -m 700 "$SSH_DIR" && install -m 700 "$TMPDIR_DL/linkctl" "$SSH_DIR/linkctl" || return 1
  if ! install -m 600 "$TMPDIR_DL"/{client.conf,identity,known_hosts,relays} "$SSH_DIR/" ||
     ! install -m 644 "$TMPDIR_DL/link.service" "$SSH_LINK_UNIT"; then
    remove_tunnel; return 1
  fi
  activate_ssh_tunnel || return 1
  info "刷新网页后选择 $SSH_TUN。检测连通性：${SELF} tunnel check"
}

setup_ssh_relay() {
  local account="$1" prefix="$2" uid
  if [[ ! "$account" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ || ! "$prefix" =~ ^[23][a-fA-F0-9]{3}:[a-fA-F0-9:]+/64$ ]] ||
     ! uid=$(id -u "$account" 2>/dev/null) || [ "$uid" -eq 0 ]; then
    err "需要现有的非 root SSH 用户及分配给中继的公网 /64"
    return 1
  fi
  if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" != 1 ]; then
    err "中继尚未开启 IPv6 转发，请按 README 配置"
    return 1
  fi
  prepare_ssh_tunnel || return 1
  write_ssh_link_unit "$TMPDIR_DL/tunnel.service" relay "$prefix" "$account" || return 1
  install -d -m 700 "$SSH_DIR" && install -m 700 "$TMPDIR_DL/linkctl" "$SSH_DIR/linkctl" || return 1
  activate_ssh_tunnel
}

do_status() {
  hr
  if installed; then
    ok "已安装 $($BIN version 2>/dev/null)"
  else
    warn "没装"
    hr; return
  fi

  local act; act=$(systemctl is-active addipv6 2>/dev/null)
  if [ "$act" = "active" ]; then ok "服务运行中"; else err "服务没在跑（$act）"; fi

  if systemctl is-enabled --quiet addipv6-restore 2>/dev/null; then
    ok "开机恢复已打开"
  else
    info "开机恢复没开（在网页上点「开机保持」）"
  fi

  local n
  n=$(grep -c '"prefix"' "$STATE_DIR/state.json" 2>/dev/null)
  info "本工具记录在案的地址：${n:-0} 个"

  if [ -f "$CONF_DIR/config.json" ] && grep -qE '"(token|globalKey)": *"[^"]' "$CONF_DIR/config.json" 2>/dev/null; then
    ok "Cloudflare 已连接"
  else
    info "Cloudflare 还没连"
  fi

  hr
  [ "$act" = "active" ] && show_access
  hr
}

do_password() {
  need_root; need_systemd || return 1
  installed || { err "还没装过"; return 1; }
  local pw="" staged
  if [ "${1:-}" != random ]; then
    printf "新密码（直接回车＝随机生成）："
    IFS= read -rs pw || return 1
    printf '\n'
  fi
  if [ -z "$pw" ]; then
    rm -f "$CONF_DIR/password" || return 1
  else
    install -d -m 700 "$CONF_DIR" || return 1
    staged=$(mktemp "$CONF_DIR/password.XXXXXX") || return 1
    if ! printf '%s\n' "$pw" > "$staged" || ! mv -f "$staged" "$CONF_DIR/password"; then
      rm -f "$staged"
      return 1
    fi
  fi
  restart_service || { err "服务重启失败，请查看日志"; return 1; }
  ok "密码已更新"
  show_access
}

do_port() {
  need_root; need_systemd || return 1
  installed || { err "还没装过"; return 1; }
  local port="${1:-}" staged
  if [ -z "$port" ]; then
    printf "新端口（当前 %s）：" "$(current_port)"
    read -r port || return 1
  fi
  valid_port "$port" || return 1
  cleanup
  staged=$(mktemp "${UNIT}.XXXXXX") || return 1
  TMPDIR_DL=$(mktemp -d) || { rm -f "$staged"; return 1; }
  if ! cp -p "$UNIT" "$TMPDIR_DL/unit" ||
     ! sed -E "/^ExecStart=/s/([[:space:]]-listen[= ][^[:space:]]*:)[0-9]+([[:space:]]|$)/\1${port}\2/" "$UNIT" > "$staged" ||
     cmp -s "$UNIT" "$staged"; then
    rm -f "$staged"
    if [ "$port" = "$(current_port)" ]; then show_access "$port"; return; fi
    err "找不到可修改的 -listen 参数"
    return 1
  fi
  if ! chmod --reference="$UNIT" "$staged" || ! mv -f "$staged" "$UNIT"; then
    rm -f "$staged"
    return 1
  fi
  if ! systemctl daemon-reload || ! restart_service; then
    if cp -p "$TMPDIR_DL/unit" "$staged" && mv -f "$staged" "$UNIT"; then
      systemctl daemon-reload && restart_service
    else
      rm -f "$staged"
    fi
    err "新端口启动失败，已尝试恢复旧配置。请查看日志"
    return 1
  fi
  ok "换到 $port 了"
  warn "防火墙记得放行新端口"
  show_access "$port"
}

menu() {
  while :; do
    printf "\n"
    hr
    printf "  ${B}addipv6${N}  批量管理 IPv6 + 解析到 Cloudflare\n"
    printf "  ${D}github.com/%s${N}\n" "$REPO"
    hr
    if installed; then
      printf "  状态：${G}已安装${N} %s  服务 %s\n" \
        "$($BIN version 2>/dev/null | awk '{print $2}')" \
        "$(systemctl is-active addipv6 2>/dev/null)"
    else
      printf "  状态：${Y}未安装${N}\n"
    fi
    hr
    printf "   1) 安装\n"
    printf "   2) 更新到最新版\n"
    printf "   3) 卸载\n"
    printf "  ${D}────${N}\n"
    printf "   4) 启动    5) 停止    6) 重启\n"
    printf "   7) 查看状态和访问地址\n"
    printf "   8) 看日志\n"
    printf "  ${D}────${N}\n"
    printf "   9) 改密码\n"
    printf "  10) 改端口\n"
    printf "  11) 配置公网 IPv6 隧道（WireGuard）\n"
    printf "   0) 退出\n"
    hr
    printf "选择: "; read -r c || return 0
    case "$c" in
      1) do_install ;;
      2) do_update ;;
      3) printf "配置和地址记录也一起删吗？(y/N): "; read -r y || return 0
         if [[ "$y" =~ ^[Yy]$ ]]; then do_uninstall purge; else do_uninstall; fi ;;
      4) systemctl start addipv6 && ok "起来了" ;;
      5) systemctl stop addipv6 && ok "停了" ;;
      6) systemctl restart addipv6 && ok "重启了" ;;
      7) do_status ;;
      8) journalctl -u addipv6 -n 50 --no-pager ;;
      9) do_password ;;
      10) do_port ;;
      11) printf "WireGuard 配置文件路径："; IFS= read -r config || return 0
          printf "服务商分配的公网路由前缀："; IFS= read -r prefix || return 0
          setup_tunnel "$config" "$prefix" ;;
      0) exit 0 ;;
      *) err "没这个选项" ;;
    esac
  done
}

access_usage() {
  printf '用法：%s access\n' "$SELF"
  printf '      %s access relay ssh <用户@中转> <TCP端口> <公网/64> <私钥> <known_hosts> [备用端点 ...]\n' "$SELF"
  printf '      %s access relay wireguard <配置文件> <公网路由前缀>\n' "$SELF"
  printf '      %s access relay serve <中转SSH用户> <公网/64>\n' "$SELF"
  printf '      %s access cloudflare <完整域名或模板> [源站公网IPv4] [--count N] [--ipv6-only]\n' "$SELF"
}

access_menu() {
  local mode transport target port prefix key known profile hostname origin count
  local args
  if [ ! -t 0 ]; then access_usage; return 0; fi
  printf '1) 公网 IPv6 中转，为 VPS 添加可路由 IPv6\n2) Cloudflare 网站代理，为域名提供 IPv4 和 IPv6 入口\n0) 退出\n'
  IFS= read -rp '选择路径 > ' mode || return 1
  case "$mode" in
    1)
      printf '1) SSH TUN（TCP）\n2) WireGuard（UDP）\n'
      IFS= read -rp '选择协议 > ' transport || return 1
      case "$transport" in
        1)
          IFS= read -rp '中转用户@公网IPv4 > ' target || return 1
          IFS= read -rp 'SSH TCP 端口 [443] > ' port || return 1
          IFS= read -rp '已路由到中转的公网 /64 > ' prefix || return 1
          IFS= read -rp '专用 SSH 私钥路径 > ' key || return 1
          IFS= read -rp '已验证的 known_hosts 路径 > ' known || return 1
          main tunnel ssh-setup "$target" "${port:-443}" "$prefix" "$key" "$known" ;;
        2)
          IFS= read -rp 'WireGuard 配置文件路径 > ' profile || return 1
          IFS= read -rp '服务商分配的公网路由前缀 > ' prefix || return 1
          main tunnel setup "$profile" "$prefix" ;;
        *) access_usage; return 1 ;;
      esac ;;
    2)
      IFS= read -rp '网站域名或模板 > ' hostname || return 1
      IFS= read -rp '源站公网 IPv4 [自动检测] > ' origin || return 1
      IFS= read -rp '域名数量 [1] > ' count || return 1
      args=("$hostname")
      if [ -n "$origin" ]; then args+=("$origin"); fi
      main cloudflare-web "${args[@]}" --count "${count:-1}" ;;
    0) return 0 ;;
    *) access_usage; return 1 ;;
  esac
}

do_access() {
  case "${1:-}" in
    '') access_menu ;;
    cloudflare) main cloudflare-web "${@:2}" ;;
    relay)
      case "${2:-}" in
        ssh) main tunnel ssh-setup "${@:3}" ;;
        wireguard) main tunnel setup "${@:3}" ;;
        serve) main tunnel ssh-relay "${@:3}" ;;
        *) access_usage; return 1 ;;
      esac ;;
    *) access_usage; return 1 ;;
  esac
}

usage() {
  printf '用法：%s [install [端口]|update|status|port [端口]|password [random]|start|stop|restart|logs|uninstall [purge]|menu]\n' "$SELF"
  tunnel_usage
  printf '      %s ipv4-to-ipv6 <IPv4> [--nat64 | --nat64-prefix <IPv6/96>]\n' "$SELF"
  printf '      %s cloudflare-web <完整域名或模板> [源站公网IPv4] [--count N] [--ipv6-only]\n' "$SELF"
  access_usage
}

main() {
  local action="${1:-}"
  if [ -z "$action" ]; then
    if [ -t 0 ] && bundle_dist >/dev/null; then action=access
    elif installed && [ -t 0 ]; then action=menu
    else action=install
    fi
  fi
  case "$action" in
    help|-h|--help) usage; return 0 ;;
    access) do_access "${@:2}"; return ;;
    ipv4-to-ipv6) require_bin_command "$action" && "$CLI_BIN" "$@"; return ;;
    cloudflare-web)
      [ "$#" -ge 2 ] || { usage; return 1; }
      need_root; do_cloudflare_web "${@:2}"; return ;;
    install|port) [ "$#" -le 2 ] || { usage; return 1; } ;;
    uninstall) [[ "$#" -le 2 && ( -z "${2:-}" || "$2" = purge ) ]] || { usage; return 1; } ;;
    password) [[ "$#" -le 2 && ( -z "${2:-}" || "$2" = random ) ]] || { usage; return 1; } ;;
    tunnel)
      case "${2:-}" in
        setup) [ "$#" -eq 4 ] && [ -n "$3" ] && [ -n "$4" ] || { tunnel_usage; return 1; } ;;
        auto|ssh-setup) [ "$#" -ge 7 ] || { tunnel_usage; return 1; } ;;
        ssh-relay) [ "$#" -eq 4 ] || { tunnel_usage; return 1; } ;;
        detect|status|check|remove) [ "$#" -eq 2 ] || { tunnel_usage; return 1; } ;;
        *) tunnel_usage; return 1 ;;
      esac ;;
    update|status|start|stop|restart|logs|menu) [ "$#" -le 1 ] || { usage; return 1; } ;;
    *) usage; return 1 ;;
  esac
  case "$action" in
    status) do_status; return ;;
    logs) journalctl -u addipv6 -n 50 --no-pager; return ;;
  esac
  if [ "$action" = tunnel ] && [ "$2" = status ]; then tunnel_status; return; fi
  if [ "$action" = tunnel ] && [ "$2" = check ]; then tunnel_check; return; fi
  if [ "$action" = tunnel ] && [ "$2" = detect ]; then tunnel_detect; return; fi
  need_root; need_systemd || return 1
  command -v flock >/dev/null || { err "缺少 flock（util-linux）"; return 1; }
  exec 9>/run/lock/addipv6-install.lock || return 1
  flock -n 9 || { err "另一个 addipv6 管理进程正在运行"; return 1; }
  case "$action" in
    install) do_install "${2:-}" ;;
    update) do_update ;;
    uninstall) do_uninstall "${2:-}" ;;
    port) do_port "${2:-}" ;;
    password) do_password "${2:-}" ;;
    start|stop) systemctl "$action" addipv6 ;;
    restart) restart_service ;;
    menu) menu ;;
    tunnel)
      case "$2" in
        setup) setup_tunnel "$3" "$4" ;;
        ssh-setup) setup_ssh_client "${@:3}" ;;
        auto) tunnel_auto "${@:3}" ;;
        ssh-relay) setup_ssh_relay "$3" "$4" ;;
        remove) remove_tunnel ;;
      esac ;;
  esac
}

main "$@"
