#!/usr/bin/env bash
set -euo pipefail

release='https://github.com/TianWen6654/addipv6/releases/download/v1.2.0/addipv6-access-linux.tar.gz'
checksum='98923fa00f99a82a535a000121ef949e15abcfbe45f132daf8bf746e248f09a2'

die() { printf '%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die '请以 root 运行此脚本。'
[ -t 0 ] || die '请在交互终端运行，以便粘贴 WireGuard 配置。'
[ "$(ps -p 1 -o comm=)" = systemd ] && [ -d /run/systemd/system ] ||
  die '该环境未运行 systemd，不能用此脚本安装中转服务。若只需要网站双栈入口，请用离线包的 access cloudflare。'
cap=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
[[ "$cap" =~ ^[[:xdigit:]]{1,16}$ ]] && (( (16#$cap & 4096) != 0 )) ||
  die '当前环境缺少 CAP_NET_ADMIN，需要在允许管理网络的 Linux 主机上运行。'

umask 077
tmp=$(mktemp -d)
cleanup() {
  rm -f "$tmp/route64.conf" "$tmp/addipv6-access-linux.tar.gz"
  if [ -d "$tmp/addipv6-access" ]; then rm -rf "$tmp/addipv6-access"; fi
  rmdir "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' '在 Route64 面板创建 WireGuard IPv6 Tunnel。选择 IPv4 对端，准备 Linux 配置和单独的 Routed /56。'
IFS= read -rp '粘贴 Route64 分配的 Routed 前缀 > ' prefix || exit 1
[[ "$prefix" =~ ^[0-9a-fA-F:]+/56$ ]] || die '请输入 Route64 面板里的 IPv6 Routed /56。'

printf '%s\n' '现在粘贴完整 WireGuard .conf。输入内容会隐藏。粘贴后另起一行输入 END 并回车。'
while IFS= read -rs line; do
  line=${line%$'\r'}
  if [ "$line" = END ]; then break; fi
  printf '%s\n' "$line"
done > "$tmp/route64.conf"
printf '\n'
[ "${line:-}" = END ] && grep -Eiq '^\s*\[Interface\]\s*$' "$tmp/route64.conf" &&
  grep -Eiq '^\s*\[Peer\]\s*$' "$tmp/route64.conf" || die '配置不完整，需要包含 [Interface] 和 [Peer]，最后输入 END。'

packages=()
command -v ip >/dev/null || packages+=(iproute2)
if ! command -v wg >/dev/null || ! command -v wg-quick >/dev/null; then packages+=(wireguard-tools); fi
command -v ping >/dev/null || packages+=(iputils-ping)
if [ "${#packages[@]}" -gt 0 ]; then
  command -v apt-get >/dev/null || die "请先安装这些依赖：${packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
fi

curl -fsSL --retry 3 -o "$tmp/addipv6-access-linux.tar.gz" "$release"
(cd "$tmp" && printf '%s  addipv6-access-linux.tar.gz\n' "$checksum" | sha256sum -c -)
tar -xzf "$tmp/addipv6-access-linux.tar.gz" -C "$tmp"
installer="$tmp/addipv6-access/addipv6-install.sh"
bash "$installer" access relay wireguard "$tmp/route64.conf" "$prefix"
bash "$installer" tunnel check
printf '%s\n' 'IPv6 隧道出站已验证，刷新 addipv6 网页，选择 addipv6-wg 即可批量加址。'
