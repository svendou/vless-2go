# VLESS-2Go：Cloudflare + Hy2 + Telegram MTProto 一键部署

一个脚本同时部署 **Cloudflare 中转、Hysteria 2（Hy2）直连、VLESS REALITY 直连备用**，并生成一个共用订阅地址。还可单独启用 **Telegram MTProto 代理（默认 TCP 53528）**，让 Telegram 通过服务器联网，无需在手机上开启 VPN。

**Hy2 为可选组件**：默认自动尝试安装；下载、证书生成、配置、启动失败或 UDP 端口被其他服务占用时，会跳过 Hy2，继续保留 Cloudflare、REALITY 和订阅服务。订阅只包含成功启用的节点，Hy2 不会反复重启；下次“安装 / 更新”会重新尝试。

Windows、iPhone、Mac 使用同一个订阅地址，更新订阅后选择想使用的节点即可。菜单支持 **↑ / ↓ 选择、Enter 确认、q 退出**。

更新日期：2026-10-22。本说明对应支持 Cloudflare HTTPS 订阅、Telegram MTProto（TCP 53528）、节点用途后缀及 CentOS 7/8、Stream 8/9/10 的新版脚本。

- [脚本页面](https://github.com/svendou/vless-2go/blob/main/deploy-personal-vpn.sh)
- [脚本下载地址](https://raw.githubusercontent.com/svendou/vless-2go/main/deploy-personal-vpn.sh)

## 1. 支持的系统

| 系统 | 版本要求 | 服务管理 / 依赖安装 |
|---|---|---|
| Ubuntu | 20.04 及以上，推荐 22.04 / 24.04 / 26.04 LTS | systemd / apt |
| Debian | 11 及以上 | systemd / apt |
| CentOS Linux 7 | 使用官方 7.9.2009 归档安装依赖 | systemd / yum |
| CentOS Linux 8 | 使用官方 8.5.2111 归档安装依赖 | systemd / dnf，兼容 yum 命令 |
| CentOS Stream | 8 / 9 / 10；Stream 8 使用对应归档 | systemd / dnf，兼容 yum 命令 |
| Rocky Linux / AlmaLinux / RHEL | 9 及以上，使用相应系统的可用软件源 | systemd / dnf |
| Alpine Linux | 推荐 3.21 及以上 | OpenRC / apk；缺少 Bash 时自动安装 |

- 支持 amd64 / x86_64、arm64 / aarch64。
- 使用 root 运行，服务器需要能访问 GitHub 下载组件，并能连接 Cloudflare。
- 订阅服务需要 Python 3.6 及以上，脚本自动安装系统提供的 Python 3 并检查版本。CentOS 7/8 的 Python 3.6 已增加订阅与 WebSocket 服务兼容，不会替换系统 Python 2。
- 普通 Docker / chroot 环境如果没有正常运行的 systemd 或 OpenRC，不能直接部署这些服务。

不需要提前准备域名或 Cloudflare 账号。普通公网服务器和配置了端口映射的 NAT 服务器均可使用。

## 2. 一键下载并运行

### 组件从哪里下载

| 组件 | 获取方式 |
|---|---|
| Xray | XTLS/Xray-core 官方 GitHub Release，校验官方 SHA-256 |
| cloudflared | cloudflare/cloudflared 官方 GitHub Release，校验官方 SHA-256 |
| Hysteria 2 | apernet/hysteria 官方 GitHub Release，校验官方 SHA-256 |
| MTProto 的 mtg | 9seconds/mtg 官方 GitHub Release，固定 v2.2.8 并校验官方 SHA-256 |
| curl、OpenSSL、Python 等系统依赖 | 通过系统包管理器，从服务器当前配置的软件源安装并验证；官方系统源同样属于官方下载 |
| jq | 通常随系统依赖安装；CentOS 7 缺少 jq，或 Debian / Ubuntu 的 APT 失败且只缺少 jq 所需命令时，下载 jqlang/jq 官方 jq 1.8.1 独立程序，校验内置 SHA-256 |

下载速度和下载地址可用性是两回事：官方源也可能因软件包清理、索引或缓存异常返回 404。jq 提供独立程序，因此可绕过失效的 jq / libjq1 包；OpenSSL、Python 等系统组件继续由包管理器处理版本与依赖，避免直接替换造成冲突。

官方下载的 jq 安装到 `/usr/local/bin/jq`，不会覆盖已有同名文件或符号链接。它属于安装依赖，卸载节点服务时保留。

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

**CentOS 7/8、CentOS Stream 8：**

已有 `curl` 时可直接使用上面的一键下载命令。原软件源失效、无法安装下载工具时，可先从电脑上传新版 `deploy-personal-vpn.sh` 到服务器 `/opt`，再执行：

```sh
sh /opt/deploy-personal-vpn.sh
```

安装过程会临时使用官方 CentOS Vault 归档源，**不改写 `/etc/yum.repos.d/` 中的原有文件**，并保留 HTTPS 证书和 RPM 签名校验。CentOS 7 使用 7.9.2009 归档，CentOS Linux 8 使用 8.5.2111，Stream 8 使用 8-stream。

需要系统原有的 CentOS RPM 签名密钥。若密钥丢失，脚本会停止并提示恢复对应发行版的 release 包密钥，不会跳过验证。CentOS 7 若没有 jq，脚本从 jq 官方下载固定版本，校验 SHA-256 后安装至 `/usr/local/bin/jq`；与系统包依赖一样，卸载节点服务时会保留它。

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
    安装 / 更新 MTProto（Telegram，53528）
    查看 MTProto 连接信息
    卸载
    退出
```

选择第一项，按 Enter。安装会部署 Cloudflare、REALITY 和订阅，并自动尝试 Hy2，没有单独的 Hy2 选项。**MTProto 需要在基础服务安装完成后，另选“安装 / 更新 MTProto（Telegram，53528）”启用。**

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
| **TCP 53528** | Telegram MTProto 直连 | 启用 MTProto 时需要；不需要 UDP 53528 |

如果是 **NAT 服务器**，还需要在服务商面板添加端口映射：

```text
公网 TCP 43518 → 内部 TCP 43518  （只在需要直连订阅备用时添加）
公网 UDP 43526 → 内部 UDP 43526
公网 TCP 43526 → 内部 TCP 43526  （使用 REALITY 时添加）
公网 TCP 53528 → 内部 TCP 53528  （使用 MTProto 时添加）
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

REALITY、HTTP 直连订阅和 MTProto 分别按需放行 TCP 43526、TCP 43518 和 TCP 53528；云服务商的安全组和 NAT 映射仍需单独配置。只使用 CF 节点和 HTTPS 订阅时，无需添加上述公网入站端口。

启用了 firewalld 且要使用 MTProto 时，可执行：

```sh
firewall-cmd --permanent --add-port=53528/tcp
firewall-cmd --reload
```

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

全部成功时订阅包含三个节点；Hy2 被跳过时只有 CF、REALITY 两个。名称根据服务器国家自动识别。例如新加坡服务器：

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

## 6. Telegram 单独走服务器：MTProto（53528）

适用于 iOS / Android / 桌面版 Telegram 的内置代理。只有 Telegram 使用此代理，其他应用不会自动使用；**不需要导入订阅，也不需要开启手机 VPN**。MTProto 不加入前面的 VLESS / Hy2 订阅。

### 安装或从旧 SOCKS5 迁移

先完成基础服务安装。已有本脚本管理的节点时，将本地新版 `deploy-personal-vpn.sh` 上传覆盖服务器 `/opt/deploy-personal-vpn.sh`，执行：

```sh
sh /opt/deploy-personal-vpn.sh mtproto
```

也可从菜单选择“安装 / 更新 MTProto（Telegram，53528）”。该命令使用官方 [mtg v2.2.8](https://github.com/9seconds/mtg/releases/tag/v2.2.8)，下载时校验官方 SHA-256，启用 MTProto FakeTLS 模式，并设置开机自启。

- 默认监听 `0.0.0.0:53528`，公网连接使用服务器 IP / 域名和 TCP `53528`。
- 自动生成随机 Secret；再次运行 `mtproto` 更新时保留原 Secret。
- 自动移除本脚本此前添加的 Xray `socks5-in` 入口及 `socks5.json`，释放旧 SOCKS5 的端口。无需先手动卸载 SOCKS5；已有其他节点配置会保留。迁移时若 Xray 正在运行，会重启它以移除旧入口。
- 无关服务占用目标端口时停止安装；安装或启动检查失败时，尝试恢复原配置及原服务状态。

只修改本地文件不会更新 VPS 或 GitHub。新版尚未上传 GitHub 时，请上传本地脚本；直接重新下载仓库旧版可能覆盖新增功能。

### 在 iPhone Telegram 中添加

安装成功后，复制输出的 `tg://proxy?...` 链接，在安装了 Telegram 的设备上打开并确认添加。也可以手动填写：

**Telegram → 设置 → 数据与存储 → 代理 → 添加代理 → MTProto**（不同版本的菜单名称可能略有差异）。

| 字段 | 填写内容 |
|---|---|
| 服务器 | 脚本显示的服务器公网 IP 或域名，不带协议前缀和端口 |
| 端口 | 默认 `53528`；NAT 使用实际公网映射端口 |
| Secret / 密钥 | 复制脚本显示的完整 Secret，包含开头的 `ee` |

**MTProto 不使用 `admin` 用户名或 SOCKS5 密码。**保存并开启该代理后测试消息连接即可；Secret 和添加链接包含访问凭据，请勿公开。

以后查看连接信息：

```sh
sh /opt/deploy-personal-vpn.sh mtproto-info
```

### NAT 端口与连接方式

默认需要在服务商面板及服务器防火墙放行 **TCP 53528**，不需要 UDP。NAT 服务器还需映射公网 TCP 53528 到内部 TCP 53528。

如果服务商提供的是公网 `54528` → 内部 `53528`，在面板完成映射后执行：

```sh
sh /opt/deploy-personal-vpn.sh mtproto \
  --mtproto-port 53528 --mtproto-public-port 54528
```

这两个参数只用于 `mtproto` 命令，不会替你修改服务商的端口映射。生成的 Telegram 链接将使用公网端口；以后不带参数更新会保留已有端口设置。

MTProto 直接连接 VPS，**不经过 Cloudflare Tunnel / CDN**。FakeTLS 中使用 `www.cloudflare.com` 作为伪装域名，不代表经过 CF 中转。手机网络、服务商协议限制和服务器到 Telegram 的出站线路仍会影响可用性，不能保证更换协议后一定连通。

## 7. 以后怎么打开菜单

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

## 8. 常用命令

```sh
# 查看订阅 URL，并导出节点备份及二维码
sh /opt/deploy-personal-vpn.sh export

# 安装 / 更新 Telegram MTProto，默认 TCP 53528
sh /opt/deploy-personal-vpn.sh mtproto

# 查看 MTProto Secret 和 Telegram 添加链接
sh /opt/deploy-personal-vpn.sh mtproto-info

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

已成功安装的服务会开机自启，包含单独启用的 MTProto；跳过的 Hy2 不会自启。`stop` 会一并停止 MTProto，并保留配置和 Secret。Cloudflare Quick Tunnel 临时域名变化后，需在服务器查看并替换客户端的 HTTPS 订阅 URL。HTTP 直连备用 URL 保持不变；启动时还未获得 Cloudflare 域名，直连订阅只显示已启用的直连节点。

## 9. 更新脚本和已部署服务

将新版脚本上传至 GitHub 后，重新执行“一键下载并运行”的命令，选择“安装 / 更新”即可。本地和服务器文件不会自动同步至 GitHub。

更新时会保留本脚本已有的 VLESS 账号、Hy2 密码、兼容的有效证书和订阅访问密钥；旧的显式曲线参数证书会重新生成并更新指纹。只要公网地址及订阅公网端口不变，HTTP 直连备用 URL 就保持不变；HTTPS URL 随临时隧道域名变化。

MTProto 使用独立服务：常规“安装 / 更新”保留已启用的 MTProto，不负责更新 mtg 程序。更新 MTProto 请另选对应菜单，或执行 `sh /opt/deploy-personal-vpn.sh mtproto`；原 Secret 和未另行指定的端口保持不变。

脚本只更新它自己管理的安装。其他服务占用必需的 TCP 端口时停止安装；占用 Hy2 的 UDP 端口时只跳过 Hy2。Cloudflare、REALITY 或订阅等必需步骤失败仍会回滚，Hy2 单独失败不会回滚其他组件。

## 10. 不使用菜单直接安装

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

## 11. 卸载

菜单选择“卸载”，或执行：

```sh
sh /opt/deploy-personal-vpn.sh uninstall
```

输入 `y` 确认。卸载会停止并删除本脚本的 Cloudflare、REALITY、Hy2、订阅和已安装的 MTProto 服务，以及管理目录中的配置、旧 SOCKS5 账号和默认导出文件。MTProto Secret 也会删除，重新安装后需要在 Telegram 更新代理信息。

SSH、防火墙和其他手动部署的服务不会被删除。自行复制的节点文件或自定义导出目录需要自行清理；卸载后重新安装会生成新的账号和订阅密钥。

## 12. 配置和导出文件在哪

| 路径 | 内容 |
|---|---|
| `/opt/deploy-personal-vpn.sh` | 部署脚本 |
| `/etc/personal-vpn-stack/settings.json` | 公网地址、端口、版本、地区等设置 |
| `/etc/personal-vpn-stack/identities.json` | 账号、密钥和订阅访问密钥，请勿公开 |
| `/etc/personal-vpn-stack/hy2.json` | Hy2 服务配置 |
| `/etc/personal-vpn-stack/mtproto.json` | MTProto Secret、内部 / 公网端口，仅 root 可读 |
| `/etc/personal-vpn-stack/mtproto.toml` | mtg 运行配置，含 Secret，仅 root 和服务组可读 |
| `/usr/local/lib/personal-vpn-stack/mtg` | MTProto 程序 |
| `/etc/personal-vpn-stack/mtproto-selinux-fcontext` | SELinux 开启时记录 MTProto 独立执行标签规则 |
| `/etc/personal-vpn-stack/selinux-fcontext` | SELinux 开启时记录本脚本管理的程序标签规则 |
| `/var/lib/personal-vpn-stack/clients/subscription-url.txt` | 默认 HTTPS 订阅地址（无隧道域名时回退为 HTTP） |
| `/var/lib/personal-vpn-stack/clients/subscription-direct-url.txt` | 原 HTTP 直连订阅备用地址 |
| `/var/lib/personal-vpn-stack/clients/subscription-url.png` | 订阅二维码，二维码依赖可用时生成 |
| `/var/lib/personal-vpn-stack/clients/all-nodes.txt` | 已启用的 CF / Hy2 / REALITY 节点备份，不含 MTProto |
| `/run/personal-vpn-stack/` | Alpine 服务运行日志，MTProto 对应 `mtproto.log` |

MTProto 的 systemd 服务名为 `personal-vpn-stack-mtproto.service`；Alpine/OpenRC 服务名为 `personal-vpn-stack-mtproto`。Secret 不通过订阅、默认节点文件或二维码导出，使用 `mtproto-info` 查看。

## 13. 常见问题

### Debian / Ubuntu 安装依赖出现 APT 404

如果 `apt-get update` 显示 `Hit`，但下载 `openssl`、`curl`、`jq` 等软件包时出现 `404 Not Found`，表示索引提供的下载地址当前不可用。可能是旧索引、缓存代理或镜像同步问题，不能仅凭 404 判断发行版已归档，也不能因此判断 MTProto 不受支持。

本版安装依赖时请求不使用 HTTP / HTTPS 缓存，并使用 `--no-upgrade` 避免顺带升级命令中已经安装的依赖包。若索引更新或软件包安装失败，会使用 `/var/tmp/personal-vpn-apt-lists.*` 下的独立新索引重试一次，并在脚本退出时清理临时索引；不会改写系统软件源或关闭签名验证。依赖解析仍可能引入必要的软件包变更。

若重建索引后仍失败，但其他必需命令、CA 证书和校验工具齐全，仅缺少 jq 命令，则改用官方 jq 1.8.1 独立程序（amd64 / arm64），通过 SHA-256 校验和运行检查后继续安装。该路径不需要 `libjq1`、`libonig5`，也不表示系统软件源问题已经解决。仍缺少其他必需工具时，脚本会停止。

将新版脚本上传覆盖 `/opt/deploy-personal-vpn.sh` 后，重新运行并选择第一项“安装 / 更新（Cloudflare + Hy2）”。若未满足 jq 备用下载条件，或官方文件下载 / 校验失败，需保留完整错误继续排查。脚本不会修复源站缺失的软件包或替换系统软件源。

### 安装 MTProto 提示 `No installation managed by this script`

MTProto 是现有基础安装的附加组件，当前脚本不支持单独安装它。新服务器或基础安装尚未成功时，先执行：

```sh
sh /opt/deploy-personal-vpn.sh
```

选择第一项“安装 / 更新（Cloudflare + Hy2）”。确认安装成功后，再执行：

```sh
sh /opt/deploy-personal-vpn.sh mtproto
```

如果第一步发生 APT 404，先解决依赖下载错误，再重试基础安装；不要手动创建安装标记文件来跳过检查。本版已将此场景的提示改为中文，并说明正确的安装顺序。

### Telegram 的 MTProto 一直连接中

先确认 Telegram 选的是 **MTProto**，服务器填写公网 IP / 域名，端口使用公网端口，Secret 完整复制，且已开启该代理。旧 SOCKS5 的账号密码不能用于 MTProto。

检查服务器监听和全部服务状态（自定义内部端口时替换 `53528`）：

```sh
ss -lntp 'sport = :53528'
sh /opt/deploy-personal-vpn.sh status
```

查看 MTProto 日志，按系统选择：

```sh
# Debian / Ubuntu / CentOS 等 systemd 系统
journalctl -u personal-vpn-stack-mtproto.service -n 50 --no-pager

# Alpine / OpenRC
rc-service personal-vpn-stack-mtproto status
tail -n 50 /run/personal-vpn-stack/mtproto.log
```

再检查服务商安全组、服务器防火墙和 NAT 的 **TCP** 映射，以及服务器系统时间是否准确。FakeTLS 对时钟偏差敏感，应确认系统时间同步正常。

脚本安装成功只确认本机服务启动并能接受 TCP 连接；外部 TCP 端口可连接也不代表 MTProto 握手、Secret 认证和 Telegram 出站连接正常。可分别用手机蜂窝网络和 Wi-Fi 测试，并向服务商核实协议限制；仅凭连接失败不能确定是服务商阻断。

### CentOS 安装在生成证书时失败，日志只有 No entries

旧版脚本第 796 行使用 `openssl req -addext` 生成 Hy2 证书。CentOS 7 常见的 OpenSSL 1.0.2 不支持 `-addext`，会在服务启动前退出，因此 systemd 日志可能显示 `No entries`。

本版已改用兼容旧版 OpenSSL 的证书配置文件，并保留生成证书时的 OpenSSL 版本和具体错误。把新版脚本上传覆盖服务器 `/opt/deploy-personal-vpn.sh`，执行 `sh /opt/deploy-personal-vpn.sh`，选择“安装 / 更新”重试即可，无需先卸载或删除原配置。

已有完整、有效的证书及私钥会继续保留。若仍失败，请查看本次输出的 `/var/tmp/personal-vpn-stack-failure.*.log`，其中会包含证书生成步骤的具体报错。

### CentOS 的 SELinux 要关闭吗

不需要手动关闭。检测到 SELinux 已开启时，脚本会安装所需管理工具，为本脚本的 Xray、cloudflared、Hy2 及单独安装的 MTProto 程序设置持久化执行标签，并在更新、失败回滚及卸载时管理自己的标签规则。遇到同路径的已有自定义规则冲突会停止并提示。

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

若安装提示“Hy2 已跳过”，订阅中不包含 Hy2 属于预期行为。独立失败日志保存在 `/var/tmp/personal-vpn-stack-hy2-failure.*.log`；端口占用会直接显示警告。修正问题后再次选择“安装 / 更新”即可重试。

CentOS 7 出现 `tls: x509: invalid ECDSA parameters` 时，新版使用 `ec_param_enc:named_curve` 并替换旧的显式曲线证书；即使 Hy2 仍失败，也会保留另外两个节点。

### 只出现两个节点，或者 Cloudflare 节点失效

隧道可能尚未生成临时域名，或已重新连接。先查看状态，必要时重建隧道，再将输出的新 HTTPS URL 替换进客户端订阅：

```sh
sh /opt/deploy-personal-vpn.sh restart-tunnel
```

### 提示 `Another stack command is running`

先确认另一个终端是否正在安装、更新或卸载，等待其结束。旧版本出现过后台进程继承锁的问题，本仓库新版已修复。若刚从旧版升级仍有占锁问题，需要先确认并处理旧进程；不要直接删除锁文件来绕过检查。

### CentOS 提示 `setpriv: failed to parse reuid`

旧版脚本将用户名传给 `setpriv --reuid/--regid`，CentOS 7 的旧版工具只接受数字 ID，导致服务尚未启动就退出。新版在生成基础服务及 MTProto 服务配置前解析独立账号的数字 UID/GID，systemd 和 Alpine/OpenRC 均使用数字参数，继续保持低权限运行。

将本版 `deploy-personal-vpn.sh` 覆盖服务器 `/opt/deploy-personal-vpn.sh` 后，执行 `sh /opt/deploy-personal-vpn.sh`，选择“安装 / 更新”。已有受管理安装会保留账号配置；更新可能使临时隧道域名变化，完成后重新查看订阅地址。若从 GitHub 下载，需先将本版脚本上传到仓库。

此错误导致的隧道超时不代表 DNS 或 7844 端口一定有问题；应先解决服务启动错误。

### Alpine 提示服务启动失败

新版已修复旧版 OpenRC 对 `respawn_period=0` 的兼容问题。若仍失败，查看脚本输出中的诊断日志路径：

```text
/var/tmp/personal-vpn-stack-failure.*.log
```

日志在回滚前保存，比回滚后查看可能已清空的应用日志更有帮助。

### 节点能连接但速度慢

Cloudflare 和 Hy2 走的路线不同，可以分别测试。中转和更换协议都不保证提速；如果两种方式都慢，优先比较手机网络、宽带、不同时间段及服务器线路。

## 14. 本版兼容性验证范围

已通过 Bash 语法、系统识别、CentOS 7/8/Stream 8 归档源生成与签名校验选项、dnf/yum/apt/apk 依赖安装分支、SELinux 标签管理的隔离检查，以及现有节点配置、订阅、卸载和失败回滚检查。

证书生成已去掉旧版 OpenSSL 不支持的 `-addext`，通过域名扩展、证书用途、密钥匹配、重复更新保留证书，以及生成失败时保存诊断的检查。

新增命名曲线生成与旧显式曲线证书修复检查，以及 systemd/OpenRC 下 Hy2 独立失败的安装流程检查；订阅服务通过动态移除 Hy2 后继续返回两个节点的验证。CentOS 实机仍需重新安装验收。

Python 3.6.8 实际运行订阅服务，通过订阅下载和两路并发 4 MiB 双向 WebSocket 转发测试。四个服务在 systemd 和 OpenRC 下均通过数字 UID/GID 参数生成及旧版数字解析行为模拟检查；包含更新时重新解析账号 ID，以及账号不存在、非数字或 root ID 时拒绝生成服务配置的检查。

此前已在 Debian 和 Alpine 服务器运行基础服务。CentOS 7/8/Stream 和 Ubuntu 尚未完成整机安装验收；归档源可用不代表所有服务器环境均已验证。

本次新增 MTProto 的本地验证包括：Bash 语法、旧 SOCKS5 入口迁移且保留其他 Xray 节点、Secret 重复更新保留、端口冲突拒绝、安装 / 更新失败恢复、NAT 公网端口链接，以及 systemd / OpenRC 服务配置生成。已使用官方 mtg v2.2.8 Windows amd64 程序实际读取生成配置并监听本机 TCP 端口；**尚未完成 Linux VPS 上的 MTProto 部署验收或手机 Telegram 端到端连接测试**。

本次 APT 调整通过模拟成功安装、下载 404 后重建索引、首次索引刷新失败、持续源故障停止、有限次数重试及可选二维码依赖失败等检查，并通过 Bash 语法检查。未在上述报错的 Debian 11 VPS 上实际执行安装，软件源是否恢复仍需服务器端验证。

本次 jq 备用路径通过模拟 APT 失败且仅缺 jq 时启用、APT 成功时不启用、缺少其他工具 / CA 证书时拒绝启用，以及已有 jq 时不误用备用路径的检查；APT 重试回归和 Bash 语法检查通过。尚未在用户 VPS 上执行下载与安装。
