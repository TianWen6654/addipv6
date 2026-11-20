# addipv6

[![Go](https://img.shields.io/badge/Go-1.23%2B-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux-lightgrey.svg)](#装哪个文件)
[![Telegram](https://img.shields.io/badge/Telegram-群聊-26A5E4?logo=telegram&logoColor=white)](https://t.me/+ft-zI76oovgwNmRh)

给 VPS 批量加随机 IPv6，勾一下就能全部解析到 Cloudflare，不要了再一键删干净。带网页界面，一个二进制跑起来就完事。

![主界面](docs/ui-overview.png)

## 跟老版本有什么不一样

这个项目原来是个 shell 脚本，能用，但有几个地方一直很别扭。这次用 Go 重写顺手都修了：

| 老的 shell 版 | 现在 |
| --- | --- |
| 靠 `python3` 算随机地址，没装就用不了 | 自带随机数，不依赖任何外部命令 |
| 靠 `ip` 命令，还得解析它的文本输出 | 直接走 netlink，不需要装 iproute2 |
| 加过的地址记在 `/tmp`，重启就丢，"一键删除"跟着失效 | 记在 `/var/lib/addipv6`，还能开机自动加回来 |
| 持久化往 `/etc/rc.local` 写，新系统基本不认 | 生成 systemd 服务，没有 systemd 才退回 rc.local |
| 随机范围覆盖整个网段，可能撞上保留地址 | 按 RFC 2526 跳过网段地址和 anycast 保留段 |
| 每执行一个功能就退出，要再来一次得重跑 | 网页界面，开着随便点 |
| 删地址没有拦一下 | 会拦住"把最后一个全局地址删掉"和"删当前出口地址" |
| 没有 Cloudflare 这回事 | 生成的地址能批量写成 AAAA，也能批量删 |

## 一条命令安装

在运行 systemd 的 Linux 服务器上执行。已登录 root 时可去掉命令里的 `sudo`。

```bash
curl -fsSL -o addipv6-install.sh https://raw.githubusercontent.com/TianWen6654/addipv6/main/install.sh && sudo bash addipv6-install.sh install
```

安装成功后会打印 Web 地址和登录密码，默认端口为 8688。想在首次安装时指定端口，在 `install` 后加端口，例如 `install 9000`。重复执行安装会沿用现有配置和端口。

保留安装脚本即可执行日常维护。

| 操作 | 命令 |
| --- | --- |
| 查看状态、Web 地址和密码 | `sudo bash addipv6-install.sh status` |
| 更新 | `sudo bash addipv6-install.sh update` |
| 修改端口 | `sudo bash addipv6-install.sh port 9000` |
| 重置为随机密码 | `sudo bash addipv6-install.sh password random` |
| 查看日志 | `sudo bash addipv6-install.sh logs` |
| 打开交互菜单 | `sudo bash addipv6-install.sh menu` |
| 卸载并保留配置 | `sudo bash addipv6-install.sh uninstall` |
| 卸载并删除配置和地址记录 | `sudo bash addipv6-install.sh uninstall purge` |

密码保存在 `/etc/addipv6/password`。可按需在防火墙放行你设置的端口。

脚本优先下载本仓库 Releases 的预编译文件并校验 SHA-256。如果发布文件不可用，会用本机的 Go 1.23 或更高版本和 Git 编译源码。维护者推送 `v*` 标签后，发布工作流会构建五个平台的二进制和校验文件。

### 装哪个文件

不想用脚本就去 [Releases](https://github.com/TianWen6654/addipv6/releases) 手动下。不知道该下哪个就先 `uname -m` 看一眼：

| `uname -m` 输出 | 下这个 | 什么机器 |
| --- | --- | --- |
| `x86_64` / `amd64` | `addipv6-linux-amd64` | 绝大多数 VPS 都是这个 |
| `aarch64` / `arm64` | `addipv6-linux-arm64` | Oracle 甲骨文的 ARM、树莓派 4/5 |
| `armv7l` / `armv6l` | `addipv6-linux-arm` | 老树莓派、部分路由器 |
| `i686` / `i386` | `addipv6-linux-386` | 很老的 32 位机器 |
| `riscv64` | `addipv6-linux-riscv64` | RISC-V 开发板 |

下完这么装：

```bash
chmod +x addipv6-linux-amd64
mv addipv6-linux-amd64 /usr/local/bin/addipv6
addipv6 -listen 0.0.0.0:8688
```

## 怎么用

多数机器只有一块带全局 IPv6 的网卡，页面会自动选好。填数量后，点击「生成并添加」即可下发。添加成功的地址会自动勾选，便于接着解析。

- 想先挑地址，点击「预览随机地址」，再勾选需要的地址并点击「加到网卡」。
- Cloudflare 凭据和站点配置好后，点击「生成、添加并解析」，核对站点与记录名后确认。工具只会解析添加成功的地址。
- 想解析已有地址，勾选地址后点击「解析勾中的地址」。记录名写法见下一节。
- 需要清理时，地址表里可选「本工具加的」，Cloudflare 记录表里可选「本工具建的」，再确认删除。

刚加上的地址可能短暂显示 `tentative`，这是 Linux 在做重复地址检测。

![深色模式](docs/ui-dark.png)

## 记录名怎么写

关键就一条：**名字里带不带 `{n}`，行为完全不一样。**

| 记录名填 | 8 个地址会变成 | 什么时候用 |
| --- | --- | --- |
| `node-{n}` | `node-1` 到 `node-8`，各一条 | 想一个地址一个域名 |
| `node-{n:3}` | `node-001` 到 `node-008` | 同上，想要补零对齐 |
| `node-{i}` | `node-0` 到 `node-7`，从 0 开始 | 习惯从 0 数 |
| `v6` | 8 条全叫 `v6`，同名多条 AAAA | 想做 DNS 轮询 |
| 留空或 `@` | 8 条全挂在根域名上 | 根域名轮询 |

不用写完整域名，`node-{n}` 会自动补成 `node-1.你的域名`。写全了也认。

界面上改完名字，下面那行小字会直接告诉你第一条长什么样，不确定就先看一眼。

## 怎么连 Cloudflare

两种都支持，界面上切一下就行。

### API Token（推荐）

去 [API Tokens](https://dash.cloudflare.com/profile/api-tokens) 页面，**Create Token** → 用 **Edit zone DNS** 模板：

- Permissions：`Zone` - `DNS` - `Edit`
- Zone Resources：`Include` - 选你要用的域名（或者 All zones）

建完复制那串贴进去。

### 全局 Key

在 [API Tokens](https://dash.cloudflare.com/profile/api-tokens) 页面最下面 **Global API Key** → View。
要填**两样**：Cloudflare 账号的登录邮箱 + 那串 Key，少一个连不上。邮箱大小写无所谓，会自动转小写。

先说清楚代价：全局 Key 是**整个账户的权限**，能改账单、能删站点、能碰你名下所有域名，而且没法按 zone 限制。
泄露一次等于 CF 账号被接管。能建 Token 就别用它——Token 可以只给一个域名的 DNS 编辑权。

顺带一提，两种认证打的接口都不一样（Token 走 `/user/tokens/verify`，全局 Key 走 `/user`），
填错类型会直接报校验失败，不会默默用错。

### 存在哪

`/etc/addipv6/config.json`，权限 600。界面上只显示头尾各四位（全局 Key 模式额外显示邮箱），
看得出是哪把但泄不出去。

## 开机保持

加上去的地址重启就没了，这是 Linux 的正常行为，不是 bug。点一下界面上的「开机保持」，它会装一个 systemd 服务：

```bash
systemctl status addipv6-restore    # 看状态
journalctl -u addipv6-restore       # 看它开机时干了啥
```

开机时会按记录把地址重新加回来，连你设的出口地址一起恢复。验证过真重启，日志长这样：

```
Starting addipv6-restore.service - addipv6 开机恢复 IPv6 地址...
level=INFO msg=恢复完成 成功=4 失败=0
Finished addipv6-restore.service - addipv6 开机恢复 IPv6 地址.
```

也可以手动跑：`addipv6 restore`。这命令是幂等的，地址已经在了就跳过，随便跑几次都行。

## 命令行参数

```
addipv6 [参数]           起 Web 界面
addipv6 restore          把记录过的地址重新加回网卡
addipv6 version          看版本
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-listen` | `0.0.0.0:8688` | 监听地址。只想本机访问就写 `127.0.0.1:8688`，然后用 SSH 隧道进来 |
| `-password` | 自动生成 | 登录密码。也可以用环境变量 `ADDIPV6_PASSWORD` |
| `-config-dir` | `/etc/addipv6` | 配置放哪 |
| `-state-dir` | `/var/lib/addipv6` | 地址记录放哪 |
| `-tls-cert` / `-tls-key` | 空 | 两个都给就走 HTTPS |
| `-restore-on-start` | 关 | 启动时先恢复一遍地址 |

## 几个要知道的事

**要 root 或者 CAP_NET_ADMIN。** 改网卡地址就是要这个权限，装出来的 systemd 服务只给了这一个能力，别的一概不给。

**公网开着记得想清楚。** 默认监听 `0.0.0.0`，图的是开箱能用。密码是随机 12 位，登录失败 5 次开始指数级锁，但要更稳妥的话建议改成 `127.0.0.1` 然后走 SSH 隧道：

```bash
ssh -L 8688:127.0.0.1:8688 root@你的服务器
```

**删地址有两道保险。** 一次删完网卡上所有全局地址会被拦下来，删当前出口地址也会被拦。真要删就勾「强制执行」——勾之前先确认你还有别的路进得去。

**批量上限 1000 个**，Cloudflare 那边按 4 次/秒发，撞到限流会自己退避重试。解析是幂等的，同名同地址的记录已经有了就跳过，重复点不会建出一堆重复解析。

**加完地址，出站源地址可能会变。** 这是内核按 RFC 6724 自己挑的，一行路由都没动它也会换。
机器上有服务绑着旧地址的话会很难查，所以加完发现出口变了工具会在日志里提醒你。
想钉死用哪个，勾中它点「设为出口」。

**IPv6 通不通是另一回事。** 这工具只管把地址加到网卡上、把解析写进 Cloudflare。
上游有没有真的把这个 /64 路由给你，得问你的服务商。加完 `ping6` 不通先这么查：

```bash
ip -6 neigh                 # 网关是 FAILED / INCOMPLETE 就是二层都没通
rdisc6 -1 -w 3000 eth0      # 收不到路由宣告，基本可以确定上游没配
```

判断是不是工具的问题有个简单办法：**拿服务商原本分配给你的那个地址做同样的测试**。
它要是也不通，那就跟工具没关系。

## 将 IPv4 写成 IPv6 地址格式

安装或更新 addipv6 后，可以用安装脚本转换，无需管理员权限。只需要转换地址时，也可单独运行 `python3 ipv4-to-ipv6.py`。

```bash
bash addipv6-install.sh ipv4-to-ipv6 192.0.2.10      # ::ffff:192.0.2.10
bash addipv6-install.sh ipv4-to-ipv6 8.8.8.8 --nat64 # 64:ff9b::808:808
bash addipv6-install.sh ipv4-to-ipv6 10.0.0.10 --nat64-prefix fd00:1234::/96
```

默认输出 IPv4 映射地址，适用于兼容双栈套接字的程序。NAT64 模式生成已有转换网关所使用的目标地址，自定义 `/96` 须与该网关配置一致。IPv4-only VPS 要获得可入站的公网 IPv6，仍需下文的路由前缀和隧道。

## 选择接入方式

离线包可运行 `bash ./addipv6-install.sh access`，在菜单里选公网 IPv6 中转或 Cloudflare 网站代理。也可以跳过菜单，直接指定路径。

| 路径 | 命令 | 结果 |
| --- | --- | --- |
| Cloudflare | `access cloudflare 'web-{n:2}.example.com' --count 10` | 为 IPv4 网站批量创建双栈入口。可在无 systemd 的容器运行 |
| SSH TUN 中转 | `access relay ssh user@中转IPv4 443 公网/64 私钥路径 known_hosts路径` | 经过 TCP 中转，为本机提供可批量加址的公网前缀 |
| WireGuard 中转 | `access relay wireguard ./provider.conf 公网路由前缀` | 经过有 UDP 连通性的中转，为本机提供可批量加址的公网前缀 |

命令前加 `bash ./addipv6-install.sh`，并把示例中的参数换成实际值。SSH 中转服务器可以用 `access relay serve` 配置。中转模式要求 Linux systemd 和相应的网络权限，公网前缀须由中转的上游实际路由。Cloudflare 网站代理使用 Cloudflare 的边缘地址，访问时使用配置好的域名。

## 用 Cloudflare 给 IPv4 网站提供 IPv6 入口

如果只需要让 IPv6 用户访问网站，可使用 Cloudflare 的免费 DNS 代理。Cloudflare 在边缘接收 IPv6 HTTP/HTTPS 请求，再通过 IPv4 回源。VPS 需要有 Cloudflare 能访问的公网 IPv4 和相应的 HTTP/HTTPS 端口。

在 addipv6 网页里保存具有 DNS 编辑权限的 Cloudflare 凭据，并选好已接入 Cloudflare 的站点。用该站点下的完整名称运行：

```bash
sudo bash addipv6-install.sh cloudflare-web web.example.com
# 或在域名后加源站公网 IPv4，适用于公网出口与源站 IP 不同的情况

# 一次创建 web-01.example.com 到 web-10.example.com
sudo bash addipv6-install.sh cloudflare-web 'web-{n:2}.example.com' --count 10

# 如果只希望发布 IPv6 入口，再追加 --ipv6-only
sudo bash addipv6-install.sh cloudflare-web 'v6-{n}.example.com' --count 10 --ipv6-only
```

省略源站 IP 时，脚本通过 IPv4 查询本机公网出口。命令创建开启代理的 A 记录，保留已有 DNS 配置；如遇冲突，可选一个新的子域名。Cloudflare 的 [IPv6 兼容性](https://developers.cloudflare.com/network/ipv6-compatibility/)负责给代理域名提供边缘 AAAA 记录。域名发布后，可在有公网 IPv6 的机器上运行 `curl -6 https://web.example.com/` 验证。该方式适用于网站，VPS 的网卡和路由配置不会改变。

默认使用双栈入口。有 IPv6 的访客可以连接 Cloudflare 的 IPv6，只有 IPv4 的访客可以连接 Cloudflare 的 IPv4，两条路径都通过 IPv4 回源。以前用 `--ipv6-only` 创建的域名，用原命令去掉该选项重新执行即可恢复双栈。脚本只自动恢复有 `addipv6` 管理标记、同名同源站且开启代理的单栈 A 记录。

批量模式会先检查所有目标域名的现有记录，遇到冲突时整批停止。若写入阶段发生 API 错误，终端会列出已完成的域名，可用相同命令补齐。仍可用 `--ipv6-only` 创建仅发布边缘 AAAA 的入口。

这些入口要用域名访问，因为 Cloudflare 使用域名识别站点和证书。多个域名可以共享同一组 Cloudflare Anycast IPv6，脚本生成的是多个入口域名。需要给 VPS 网卡批量分配公网 IPv6 时，使用下节的路由前缀。若 HTTPS 使用 Cloudflare Universal SSL，常规接入站点请使用 `web-01.example.com` 这类一级子域名，并让源站接受这些域名的请求。

如果源站没有可用的入站端口，可以考虑 [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/troubleshooting/)。在限制 UDP 的网络可用 HTTP/2，但 `cloudflared` 仍要求出站 TCP `7844`。只有出站 TCP `443` 且无公网回源的 VPS 无法使用这两种接入方式。

使用含 `dist/SHA256SUMS` 的离线包时，解压后直接运行包内 `addipv6-install.sh`。脚本会验证并使用同包预编译二进制。`cloudflare-web` 可以在无 systemd 的容器运行，并优先采用现有 addipv6 配置。没有配置文件时，可以用具有该站点 DNS 编辑权限的 Token 和站点的 Zone ID 直接连接：

```bash
read -rsp 'Cloudflare API Token: ' ADDIPV6_CF_TOKEN; echo
export ADDIPV6_CF_TOKEN
bash ./addipv6-install.sh cloudflare-web 'web-{n:2}.example.com' --count 10 --zone example.com --zone-id '替换为实际ZoneID'
unset ADDIPV6_CF_TOKEN
```

## 没有原生 IPv6 时建立公网隧道

在只有 IPv4 的 Linux 服务器上，先确认出站条件。能发 UDP 可用 WireGuard 隧道服务。只允许 TCP 出站时，使用下文的 SSH TUN。两种方式都需要由隧道服务商或中继上游分配并路由公网 IPv6 网段。

### 能发 UDP 时使用 WireGuard

以下以 [Route64](https://route64.org/) 为例。服务器需要启用内核 IPv6 和 WireGuard 支持，并能通过 IPv4 向服务商的 UDP 端点发包。

1. 在服务商面板创建 **WireGuard IPv6 tunnel**，下载 Linux 客户端 `.conf`，同时记下单独分配的 **Routed** 前缀，例如 `/56`。端点选 IPv4。配置文件含私钥，请仅传到要配置的服务器。
2. 在有 systemd、`iproute2` 和 `wireguard-tools` 的服务器上运行以下命令。把配置文件路径和前缀换成面板提供的值。

```bash
sudo bash addipv6-install.sh tunnel setup ./route64.conf 2001:db8:1234:5600::/56
```

安装器会启动并保存 `addipv6-wg` 隧道，从 Routed 前缀选第一个 `/64` 供批量加址。刷新网页即可选择这块网卡。隧道的传输地址单独保留。导入只使用配置里的 WireGuard 连接参数，不执行服务商文件里的脚本，也不改原有 IPv4 路由或 DNS。服务器重启时隧道先于 Web 和地址恢复服务启动。要让之后批量添加的地址也随开机恢复，点击网页「开机保持」。

| 操作 | 命令 |
| --- | --- |
| 查看隧道、地址和 IPv6 默认路由 | `sudo bash addipv6-install.sh tunnel status` |
| 通过隧道探测 IPv6 出站 | `sudo bash addipv6-install.sh tunnel check` |
| 移除隧道 | `sudo bash addipv6-install.sh tunnel remove` |

隧道服务已启动只代表本机配置成功。验证公网入站时，从另一台具有公网 IPv6 的设备访问绑定到该地址的服务，并检查服务器 IPv6 防火墙放行了相应端口。处于 NAT 下的客户端会发送 WireGuard keepalive 来维持 UDP 映射。若内核通过启动参数禁用了 IPv6，需要先启用 IPv6。

### 只有 TCP 出站时使用 SSH TUN

准备一台可从 VPS 通过 IPv4 和 TCP 访问的 Linux 中继。中继须有 IPv6 互联网连接，并且上游已把独立的公网 `/64` 路由到它。两端都需要 systemd、`iproute2`、`/dev/net/tun` 和 OpenSSH。中继的 SSH 端口必须在 VPS 的 TCP 出站许可内。只有 TCP 443 可用时，可以让中继的 OpenSSH 监听空闲的 443 端口；若出站策略要求 HTTPS，SSH 无法通过该检查。

1. **在中继上**，为现有的专用非 root 账号配置公钥登录。在 `authorized_keys` 的对应公钥前加 `tunnel="64"`，并给这个账号启用下列 `sshd_config` 设置。用 `sshd -t` 检查配置，然后按发行版方式重载 SSH 服务。

   ```text
   Match User ipv6relay
       PermitTunnel point-to-point
       PasswordAuthentication no
       KbdInteractiveAuthentication no
       AllowAgentForwarding no
       AllowTcpForwarding no
       AllowStreamLocalForwarding no
       X11Forwarding no
       PermitTTY no
       PermitUserRC no
       MaxSessions 0
   ```

   在中继开启 IPv6 转发（`net.ipv6.conf.all.forwarding=1`）并按既有防火墙规则放行该 `/64` 的转发。限制 `tun64` 进来的转发流量只能使用这个 `/64` 作为源地址。如果中继的 IPv6 默认路由来自 RA，先将上联网卡的 `accept_ra` 设为 `2`，让它在开启转发后仍接受 RA。然后运行：

   ```bash
   sudo bash addipv6-install.sh tunnel ssh-relay ipv6relay 2001:db8:1234:5600::/64
   ```

2. **在只有 TCP 出站的 VPS 上**，使用专用无口令 SSH 私钥，以及已核对中继主机指纹的 `known_hosts` 文件。建议直接填中继的公网 IPv4，避免依赖 UDP DNS。`known_hosts` 也须包含该地址和端口对应的主机密钥。把示例里的地址、端口、前缀和文件路径换成实际值：

   ```bash
   sudo bash addipv6-install.sh tunnel ssh-setup ipv6relay@198.51.100.10 443 2001:db8:1234:5600::/64 ~/.ssh/ipv6-relay ~/.ssh/known_hosts
   sudo bash addipv6-install.sh tunnel check
   ```

SSH 断开后会自动重连，`tun64` 和已经加上的 IPv6 会留在本机。网页刷新后选 `tun64` 即可批量加地址。需要重启后恢复批量添加的地址时，点击网页「开机保持」。已经配置 WireGuard 的机器可先运行 `tunnel remove`，再切换传输方式。

#### 自动判断和故障切换

- `tunnel detect` 读取本机 IPv4/IPv6 路由，并尝试通过 IPv6 连接公网 TCP 443。退出码 `0` 表示 IPv6 出站通过，`2` 表示发现 IPv4 路由且未发现公网 IPv6 路由，`3` 表示 IPv6 探测失败但已有路由或无法判断。
- 把 `ssh-setup` 换成 `auto`，脚本先检测本机。有可用 IPv6 时直接返回，仅有 IPv4 路由时才配置隧道。已经存在但无法验证的 IPv6 路由保留原样。
- 在命令末尾依次追加 `用户@备用IPv4:端口`。也可把同一台中继的其他已授权 SSH 监听端口列为备用。系统服务按顺序检查 TCP、验证 SSH 主机密钥并通过 `tun64` 检测 IPv6，持续故障时切到下一端点。当前端点健康时继续使用它，全部不可用时逐渐延长重试间隔。

```bash
sudo bash addipv6-install.sh tunnel auto ipv6relay@198.51.100.10 443 2001:db8:1234:5600::/64 ~/.ssh/ipv6-relay ~/.ssh/known_hosts ipv6relay@198.51.100.10:22 ipv6relay@198.51.100.20:443
```

各端点须授权同一客户端公钥，并在 `known_hosts` 中预先验证。可切换的多台中继需要事先由上游为同一个 `/64` 配置路由切换，否则脚本只能重建本地连接，原有入站 IPv6 和 AAAA 无法随中继迁移。健康检测使用 IPv6 ICMP，无法探测时可通过 `journalctl -u addipv6-tunnel` 查看切换原因。安装器只测试用户登记的中继和端口。

[Route64 的免费 IPv6 隧道](https://route64.org/) 提供路由前缀，接入可用 WireGuard 或其他非 TCP 隧道协议。TCP 模式需要已经授权且有上游前缀的中继。普通网络代理和应用隧道无法为这里的批量加址功能分配公网前缀。

## 服务商已经分配了 6in4 隧道

有些服务商（KiwiVM 面板那一挂，搬瓦工之类）给的 IPv6 **不是原生的，是 6in4 SIT 隧道**。
这种机器直接往 `eth0` 上配 IPv6 怎么弄都不通——因为流量压根不走 `eth0`。

面板上会给你隧道两端的地址，照着建一个隧道接口：

```bash
ip tunnel add ipv6net mode sit local <你的IPv4> remote <面板给的对端> ttl 255
ip link set ipv6net up mtu 1480
ip addr add <你的IPv6>/64 dev ipv6net
ip route add ::/0 dev ipv6net
```

Debian/Ubuntu 写进 `/etc/network/interfaces` 持久化：

```
auto ipv6net
iface ipv6net inet6 v4tunnel
    address <你的IPv6>
    netmask 64
    endpoint <面板给的对端>
    local <你的IPv4>
    ttl 255
    gateway <面板给的网关>
```

弄好之后 `ipv6net` 会作为一块网卡出现在界面的下拉框里，跟普通网卡一样用。
这种隧道是点对点链路，默认路由长这样 `default dev ipv6net`，**没有网关**，工具认得这种形态。

面板上有「关机再开机」选项的话也可以让它自动配（注意是完全关机再开，`reboot` 不算）。

## 自己编译

```bash
git clone https://github.com/TianWen6654/addipv6.git
cd addipv6
go build .          # 就编当前平台
./build.sh          # 编全部五个平台，产物在 dist/
go test ./...       # 跑测试
```

## 协议

MIT，见 [LICENSE](LICENSE)。

## 关于

作者 Joey，原项目是一个 shell 脚本，这版是 Go 重写并加上了网页界面和 Cloudflare 批量解析。

- 博客 [joeyblog.net](https://joeyblog.net)
- TG 群 [t.me/+ft-zI76oovgwNmRh](https://t.me/+ft-zI76oovgwNmRh)
- YouTube [@joeyblog](https://youtube.com/@joeyblog)
- GitHub [@byJoey](https://github.com/byJoey)

**免责**：这工具会改你机器的网络配置。操作前请确保你有别的方式能连上服务器（比如 VNC 或者救援模式）。因使用本工具造成的任何损失，作者不承担责任。合理使用。
