# VLESS-2Go：Cloudflare + Hy2 一键部署

一个脚本同时部署 **Cloudflare 中转、Hysteria 2（Hy2）直连、VLESS REALITY 直连备用**，并生成一个共用订阅地址。

Windows、iPhone、Mac 使用同一个订阅地址，更新订阅后选择想使用的节点即可。菜单支持 **↑ / ↓ 选择、Enter 确认、q 退出**。

更新日期：2026-10-20。本说明对应支持 Cloudflare HTTPS 订阅、节点用途后缀及 CentOS Stream 9/10 的新版脚本。

- [脚本页面](https://github.com/svendou/vless-2go/blob/main/deploy-personal-vpn.sh)
- [脚本下载地址](https://raw.githubusercontent.com/svendou/vless-2go/main/deploy-personal-vpn.sh)

## 1. 支持的系统

| 系统 | 版本要求 | 服务管理 / 依赖安装 |
|---|---|---|
| Ubuntu | 20.04 及以上，推荐 22.04 / 24.04 / 26.04 LTS | systemd / apt |
| Debian | 11 及以上 | systemd / apt |
| CentOS Stream | 9 / 10 | systemd / dnf，兼容 yum 命令 |
| Rocky Linux / AlmaLinux / RHEL | 9 及以上，使用相应系统的可用软件源 | systemd / dnf |
| Alpine Linux | 推荐 3.21 及以上 | OpenRC / apk；缺少 Bash 时自动安装 |

- 支持 amd64 / x86_64、arm64 / aarch64。
- 使用 root 运行，服务器需要能访问 GitHub 下载组件，并能连接 Cloudflare。
- 订阅服务需要 Python 3.8 及以上，脚本自动安装系统提供的 Python 3 并检查版本。
- CentOS 7/8 不在本版支持范围内。普通 Docker / chroot 环境如果没有正常运行的 systemd 或 OpenRC，也不能直接部署这些服务。

不需要提前准备域名或 Cloudflare 账号。普通公网服务器和配置了端口映射的 NAT 服务器均可使用。

## 2. 一键下载并运行

先用 SSH 登录服务器，切换为 root。下面的命令在 **Linux 服务器终端**执行：

```sh
mkdir -p /opt && curl -fsSL --retry 2 https://raw.githubusercontent.com/svendou/vless-2go/main/deploy-personal-vpn.sh -o /opt/deploy-personal-vpn.sh && sh /opt/deploy-personal-vpn.sh
```

如果提示 `curl: not found`，按系统先安装下载工具，再执行上面的命令。

**Debian / Ubuntu：**

```sh
apt-get update && apt-get install -y curl ca-certificates
```

**Alpine：**

```sh
apk add --no-cache curl ca-certificates
```

**CentOS Stream 9/10、Rocky Linux / AlmaLinux / RHEL 9+：**

```sh
dnf install -y ca-certificates
if ! command -v curl >/dev/null 2>&1; then dnf install -y curl; fi
```

已经提供 `curl` 命令的精简系统可以直接使用它，包括 `curl-minimal`，无需替换。

菜单需要交互输入，请使用上面的“下载到文件后运行”方式，不要改成 `curl ... | sh`。

## 3. 首次安装怎么选

菜单内容：

```text
个人节点部署
  > 安装 / 更新（Cloudflare + Hy2）
    查看订阅链接
    更改 CF 入口
    重建临时隧道并更新订阅
    查看运行状态
    卸载
    退出
```

选择第一项，按 Enter。安装会同时部署全部方案，没有单独的 Hy2 选项。

遇到输入提示时，**直接按 Enter 使用方括号中的默认值**：

| 提示 | 应该怎么填 |
|---|---|
| 服务器公网 IP / 域名 | 一般直接回车；NAT 服务器要核对服务商提供的公网 IP |
| 备用直连内部 TCP 端口 | 默认 `43526` |
| 备用直连公网 TCP 端口 | 默认与内部相同；NAT 映射不同则填实际公网端口 |
| Cloudflare 入口 | 新安装默认 `cdns.doon.eu.org`；更新保留原设置；填 `auto` 使用自己的隧道域名 |
| Hy2 内部 UDP 端口 | 默认 `43526` |
| Hy2 公网 UDP 端口 | 默认 `43526`；NAT 映射不同则填实际公网端口 |
| 订阅内部 TCP 端口 | 默认 `43518` |
| 订阅公网 TCP 端口 | 默认 `43518`；NAT 映射不同则填实际公网端口 |

脚本会自动安装依赖、下载并校验官方组件、生成账号和证书、启动服务，最后显示订阅地址。

## 4. 需要开放哪些端口

使用默认端口时，在服务商防火墙或安全组放行：

| 端口 | 用途 | 是否需要 |
|---|---|---|
| **TCP 43518** | 直连 HTTP 订阅备用 | 仅使用直连备用订阅时需要；默认 HTTPS 订阅不需要 |
| **UDP 43526** | Hy2 直连 | 使用 Hy2 时需要 |
| **TCP 43526** | REALITY 直连备用 | 使用 REALITY 时需要 |

如果是 **NAT 服务器**，还需要在服务商面板添加端口映射：

```text
公网 TCP 43518 → 内部 TCP 43518  （只在需要直连订阅备用时添加）
公网 UDP 43526 → 内部 UDP 43526
公网 TCP 43526 → 内部 TCP 43526  （使用 REALITY 时添加）
```

TCP 和 UDP 是不同协议，同一个 `43526` 可以分别使用。

Cloudflare 节点和默认 HTTPS 订阅均不需要公网入站映射。服务器要允许向 Cloudflare 发起 **TCP 7844 出站连接**；客户端连接 Cloudflare 节点使用 HTTPS 443。

`48089` 和 `48090` 只监听服务器本机，不需要公网开放。脚本不会自动修改服务商面板、防火墙或 SSH 端口。

CentOS 等系统若启用了 firewalld，使用 Hy2 还需在服务器防火墙放行 UDP 43526。例如：

```sh
# 仅在 firewalld 正在运行、且要使用 Hy2 时执行
firewall-cmd --permanent --add-port=43526/udp
firewall-cmd --reload
```

REALITY 和 HTTP 直连订阅分别按需放行 TCP 43526、TCP 43518；云服务商的安全组和 NAT 映射仍需单独配置。只使用 CF 节点和 HTTPS 订阅时，无需添加上述公网入站端口。

## 5. 怎么导入订阅

安装结束后会显示类似：

```text
https://自动生成的域名.trycloudflare.com/自动生成的随机访问密钥
```

这是**订阅地址**，不是单节点分享地址。操作步骤：

1. 复制脚本显示的完整订阅 URL。
2. 在客户端打开“订阅”“订阅分组”或“添加配置链接”。
3. 新增订阅，将 URL 粘贴到订阅地址栏并保存。
4. 执行“更新订阅”，再选择节点连接。

订阅包含三个节点，名称根据服务器国家自动识别。例如新加坡服务器：

```text
SG-CF-主力             Cloudflare 中转，日常优先选择
SG-Hy2-备用            Hysteria 2 直连，主力不可用时尝试
SG-REALITY-不建议使用   VLESS REALITY 直连，保留用于测试
```

美国、日本服务器分别使用 `US-`、`JP-` 前缀，用途后缀相同。识别失败时使用服务器地址作为前缀。所有设备可以使用同一个订阅、同一个账号。主力、备用等后缀用于区分用途，客户端不会仅凭名称自动切换节点。

客户端需要同时支持 VLESS、Hysteria 2 和 Base64 节点订阅。例如支持相应协议的 v2rayN、Hiddify、Shadowrocket 版本；使用 v2rayN 时还需选用支持 Hy2 的核心。**本订阅不是 Clash/Mihomo YAML 配置，不能直接当作 YAML 配置文件导入。**

Hy2 使用自动生成的自签证书，链接包含固定证书指纹 `pinSHA256`，客户端需支持并保留该指纹。默认没有人为设置带宽上限，实际速度取决于运营商和线路。

> 默认订阅通过自己的 Cloudflare 临时域名提供 HTTPS，本地无法直达服务器 TCP 43518 时可使用它。订阅包含账号凭据，请勿公开。原 HTTP 直连订阅保留在 `subscription-direct-url.txt`，使用它仍需开放 TCP 43518。
>
> Quick Tunnel 免费临时域名可能在服务器重启或隧道重建后改变，HTTPS 订阅地址也会随之改变；请在菜单选择“查看订阅链接”，替换客户端中的旧地址。它不能保证在所有本地网络中可访问，也不保证长期固定。

## 6. 以后怎么打开菜单

已经下载过脚本，直接执行：

```sh
sh /opt/deploy-personal-vpn.sh
```

也可以在 `/opt` 下运行：

```sh
cd /opt
chmod +x deploy-personal-vpn.sh
./deploy-personal-vpn.sh
```

查看订阅地址不需要重新安装，选择“查看订阅链接”即可。

### 更改 CF 入口：不需要重建隧道

1. 主菜单选择“更改 CF 入口”。
2. 用 ↑ / ↓ 从 `cdns.doon.eu.org`、`cf.090227.xyz`、`cloudflare-ip.mofashi.ltd`、`saas.sin.fan` 中选择，Enter 保存。
3. 在 v2rayN、Shadowrocket 等客户端更新该订阅。
4. 选择更新后的 `SG-CF-主力`（其他地区前缀不同），断开后重新连接。

四项均使用 443 端口，当前入口会有标记；按 q 或选择“返回主菜单”取消。

**更改入口不会重建隧道，订阅地址和隧道域名都不变，Hy2、REALITY 也不受影响。**入口是客户端连接 CF 节点时使用的地址，隧道域名用于识别自己的隧道；HTTPS 订阅继续使用自己的隧道域名。

“重建临时隧道并更新订阅”是另一个操作，仅在需要恢复隧道时使用。它可能改变临时域名，届时需要替换客户端中的 HTTPS 订阅地址。

## 7. 常用命令

```sh
# 查看订阅 URL，并导出节点备份及二维码
sh /opt/deploy-personal-vpn.sh export

# 查看全部服务和 Cloudflare 隧道状态
sh /opt/deploy-personal-vpn.sh status

# 重建 Cloudflare 临时隧道，随后使用输出的新 HTTPS 订阅 URL
sh /opt/deploy-personal-vpn.sh restart-tunnel

# 恢复 Cloudflare 自动入口，订阅 URL 保持不变
sh /opt/deploy-personal-vpn.sh set-entry --cf-entry auto

# 停止全部服务，保留配置和账号
sh /opt/deploy-personal-vpn.sh stop

# 查看完整参数说明
sh /opt/deploy-personal-vpn.sh help
```

四个服务会开机自启。Cloudflare Quick Tunnel 临时域名变化后，需在服务器查看并替换客户端的 HTTPS 订阅 URL。HTTP 直连备用 URL 保持不变；启动时还未获得 Cloudflare 域名，直连订阅会先显示两个直连节点。

## 8. 更新脚本和已部署服务

将新版脚本上传至 GitHub 后，重新执行“一键下载并运行”的命令，选择“安装 / 更新”即可。本地和服务器文件不会自动同步至 GitHub。

更新时会保留本脚本已有的 VLESS 账号、Hy2 密码、证书和订阅访问密钥。只要公网地址及订阅公网端口不变，HTTP 直连备用 URL 就保持不变；HTTPS URL 随临时隧道域名变化。

脚本只更新它自己管理的安装；遇到其他服务占用端口时会停止安装，避免覆盖。安装阶段失败会尝试恢复本脚本管理的文件。

## 9. 不使用菜单直接安装

这是可选方式，一般使用菜单即可。首次非交互安装需要提供公网地址，将 `YOUR_SERVER_IP` 换成自己的公网 IP：

```sh
sh /opt/deploy-personal-vpn.sh install --server YOUR_SERVER_IP
```

指定地区代号：

```sh
sh /opt/deploy-personal-vpn.sh install --server YOUR_SERVER_IP --country US
```

公网映射端口与内部端口不同时，可分别填写：

```sh
sh /opt/deploy-personal-vpn.sh install --server YOUR_SERVER_IP \
  --hy2-port 43526 --hy2-public-port 43526 \
  --subscription-port 43518 --subscription-public-port 43518 \
  --reality-port 43526 --public-port 43526
```

## 10. 卸载

菜单选择“卸载”，或执行：

```sh
sh /opt/deploy-personal-vpn.sh uninstall
```

输入 `y` 确认。卸载会停止并删除本脚本的 Cloudflare、REALITY、Hy2、订阅服务，以及管理目录中的配置和默认导出文件。

SSH、防火墙和其他手动部署的服务不会被删除。自行复制的节点文件或自定义导出目录需要自行清理；卸载后重新安装会生成新的账号和订阅密钥。

## 11. 配置和导出文件在哪

| 路径 | 内容 |
|---|---|
| `/opt/deploy-personal-vpn.sh` | 部署脚本 |
| `/etc/personal-vpn-stack/settings.json` | 公网地址、端口、版本、地区等设置 |
| `/etc/personal-vpn-stack/identities.json` | 账号、密钥和订阅访问密钥，请勿公开 |
| `/etc/personal-vpn-stack/hy2.json` | Hy2 服务配置 |
| `/etc/personal-vpn-stack/selinux-fcontext` | SELinux 开启时记录本脚本管理的程序标签规则 |
| `/var/lib/personal-vpn-stack/clients/subscription-url.txt` | 默认 HTTPS 订阅地址（无隧道域名时回退为 HTTP） |
| `/var/lib/personal-vpn-stack/clients/subscription-direct-url.txt` | 原 HTTP 直连订阅备用地址 |
| `/var/lib/personal-vpn-stack/clients/subscription-url.png` | 订阅二维码，二维码依赖可用时生成 |
| `/var/lib/personal-vpn-stack/clients/all-nodes.txt` | 三节点备份 |
| `/run/personal-vpn-stack/` | Alpine 服务运行日志 |

## 12. 常见问题

### CentOS 的 SELinux 要关闭吗

不需要手动关闭。检测到 SELinux 已开启时，脚本会安装所需管理工具，为本脚本的 Xray、cloudflared、Hy2 程序设置持久化执行标签，并在更新、失败回滚及卸载时管理自己的标签规则。遇到同路径的已有自定义规则冲突会停止并提示。

脚本不会关闭 SELinux，不会自动启用 EPEL 等额外软件源。若当前软件源未提供二维码工具，安装会继续完成，并提供可复制的订阅链接。

### HTTPS 订阅地址能用多久

Cloudflare Quick Tunnel 临时域名**没有固定有效期，也没有长期可用保证**。隧道进程持续正常运行时，同一个地址可能使用数天甚至更久。

| 操作或情况 | 是否需要更换 HTTPS 订阅地址 |
|---|---|
| 更改 CF 入口、查看订阅链接、客户端更新订阅 | 不需要；更改入口后更新订阅并重新连接 CF 节点即可 |
| 普通网络断线后，原隧道进程自动重连 | 不一定；以服务器当前显示的域名为准 |
| 服务器重启、隧道进程重启、手动重建隧道 | 域名可能变化；变化后需要替换 |
| 安装 / 更新脚本 | 若更新导致隧道重启，域名可能变化；以安装结束时输出的地址为准 |

地址失效后，SSH 登录服务器，执行 `sh /opt/deploy-personal-vpn.sh export`，或在菜单选择“查看订阅链接”。把新地址替换到客户端原有订阅分组的 URL 中，再更新订阅。

旧订阅地址失效不会直接删除客户端已导入的节点，但旧域名对应的 CF 节点可能无法连接。Hy2、REALITY 使用服务器公网地址，仍取决于各自直连线路是否可用。

原 HTTP 直连备用 URL 不随隧道域名变化；公网地址、订阅端口和访问密钥不变时，可继续使用。需要长期固定的 HTTPS 地址时，可另行配置自有域名和 Cloudflare 命名隧道；当前脚本部署的是免费临时隧道。

### 订阅地址连接超时

先确认用的是新 HTTPS 订阅 URL，且临时域名没有变化。菜单“查看订阅链接”可重新查看。仅使用 HTTP 直连备用 URL 时才需检查公网 **TCP 43518** 和 NAT 映射。再执行：

```sh
sh /opt/deploy-personal-vpn.sh status
```

单独检查订阅服务，按系统选择：

```sh
# Alpine
rc-service personal-vpn-stack-subscription status

# Debian / Ubuntu
systemctl status personal-vpn-stack-subscription --no-pager
```

### 订阅能更新，但 Hy2 无法连接

检查是否开放了 **UDP 43526**，而不只是 TCP。NAT 公网端口与内部端口不同时，需要在安装时填写正确的 Hy2 公网端口。还需确认客户端支持 Hy2 和证书指纹校验。

### 只出现两个节点，或者 Cloudflare 节点失效

隧道可能尚未生成临时域名，或已重新连接。先查看状态，必要时重建隧道，再将输出的新 HTTPS URL 替换进客户端订阅：

```sh
sh /opt/deploy-personal-vpn.sh restart-tunnel
```

### 提示 `Another stack command is running`

先确认另一个终端是否正在安装、更新或卸载，等待其结束。旧版本出现过后台进程继承锁的问题，本仓库新版已修复。若刚从旧版升级仍有占锁问题，需要先确认并处理旧进程；不要直接删除锁文件来绕过检查。

### Alpine 提示服务启动失败

新版已修复旧版 OpenRC 对 `respawn_period=0` 的兼容问题。若仍失败，查看脚本输出中的诊断日志路径：

```text
/var/tmp/personal-vpn-stack-failure.*.log
```

日志在回滚前保存，比回滚后查看可能已清空的应用日志更有帮助。

### 节点能连接但速度慢

Cloudflare 和 Hy2 走的路线不同，可以分别测试。中转和更换协议都不保证提速；如果两种方式都慢，优先比较手机网络、宽带、不同时间段及服务器线路。

## 13. 本版兼容性验证范围

已通过 Bash 语法、系统识别、dnf/yum/apt/apk 依赖安装分支、SELinux 标签管理的隔离检查，以及现有节点配置、订阅、卸载和失败回滚检查。

此前已在 Debian 和 Alpine 服务器运行基础服务。本次新增 CentOS 适配，以及 Ubuntu 的依赖流程，尚未在 CentOS / Ubuntu 实机完成安装验收。
