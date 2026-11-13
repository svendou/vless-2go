# 个人节点部署脚本

基于 **Xray** 的个人节点部署与管理脚本，提供中文一、二级菜单。Xray 提供 VLESS REALITY 和经过 Cloudflare 隧道的 WebSocket 节点；独立 Hysteria2 服务提供 Hy2；Telegram MTProto 使用单独安装的 mtg。

首次安装使用默认端口，按提示确认地址和 Hy2 开关即可。安装后可查看订阅、修改设置、更新版本和管理服务。

首次安装的默认版本如下；已有安装会优先保留配置中记录的版本。

| 组件 | 默认版本 |
| --- | --- |
| Xray | `v26.11.9` |
| Hysteria2 | `app/v2.13.0` |
| cloudflared | `2026.10.1` |
| mtg（单独安装） | `v2.3.0` |

程序从官方发布页面下载并校验 SHA-256。菜单顶部显示服务器地址、实际安装的核心版本、Hy2 配置状态、CF 入口、服务状态及已安装的 mtg 版本。

## 使用条件

- 一台有 root 权限、能够访问 GitHub 和 Cloudflare 的 Linux 服务器。
- 支持 amd64 / arm64 架构。
- 系统适配：Ubuntu 20.04+、Debian 11+、CentOS 7+ / RHEL 系列（systemd），以及 Alpine（OpenRC）。建议优先使用仍受维护的系统版本。
- NAT 服务器需提前确认公网地址，以及服务商提供的 TCP / UDP 映射端口。

## 开始使用

仓库地址：[svendou/vless-2go](https://github.com/svendou/vless-2go)。以 root 登录服务器，确认已安装 `curl`，即可直接从 GitHub 下载脚本，无需安装 Git 或手动上传。

**下载最新版脚本并打开中文菜单（推荐）：**

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/svendou/vless-2go/main/deploy-personal-vpn.sh -o deploy-personal-vpn.sh && bash deploy-personal-vpn.sh
```

**下载并直接安装基础节点：** 将 `YOUR_PUBLIC_IP` 替换为服务器公网 IPv4 或域名。

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/svendou/vless-2go/main/deploy-personal-vpn.sh -o deploy-personal-vpn.sh && bash deploy-personal-vpn.sh install --server YOUR_PUBLIC_IP
```

直接安装使用默认端口，首次安装默认启用 Hy2；TG 代理和连接防护需在基础安装完成后分别安装。NAT 服务器需增加下方“端口设置”中的公网映射参数。

命令使用 `main` 分支的 Raw 原始文件地址；GitHub 的 `/blob/` 链接是网页，不能直接作为脚本执行。脚本会调用自身处理菜单操作，因此先保存到文件再运行。再次运行下载命令可获取仓库中的最新脚本；更新核心版本仍需选择菜单中的更新项或指定版本参数。

也可下载 [deploy-personal-vpn.sh](deploy-personal-vpn.sh) 后上传到服务器。已有本地文件时直接运行：

```bash
bash deploy-personal-vpn.sh
```

Alpine 未安装 Bash 时，运行：

```sh
sh deploy-personal-vpn.sh
```

进入 **安装与更新 → 安装 / 调整节点配置**，按提示操作：

1. 确认服务器的公网 IP 或域名。
2. 确认 Cloudflare 入口；填写 `auto` 可使用当前隧道域名。
3. 选择是否启用 Hy2，默认启用。

直接回车即可采用方括号中的默认值，无需逐项输入端口。安装完成后，终端会显示订阅链接。

需要自定义端口时，可在安装后再次进入“安装 / 调整节点配置”；首次安装到 NAT 服务器，也可使用下方命令指定映射端口。

## 菜单

```text
1. 安装与更新
   ├─ 安装 / 调整节点配置
   ├─ 重新安装（保留当前配置）
   └─ 更新 Xray 至最新稳定版（保留配置）
2. 节点与订阅
   ├─ 查看节点、订阅与二维码
   ├─ 更换 CF 入口
   └─ 重建 CF 隧道（订阅域名会变化）
3. Telegram 代理
   ├─ 安装 / 更新 TG 代理
   ├─ 查看 TG 代理链接
   ├─ 安装 / 配置连接防护
   └─ 配置自动校时
4. 服务控制
   ├─ 启动全部服务
   ├─ 重启代理与订阅（保留 CF 隧道）
   └─ 停止全部服务
5. 状态与日志
   ├─ 查看状态、版本与端口
   └─ 查看最近服务日志
6. 卸载全部组件
0. 退出
```

支持方向键、j/k 或数字选择，Enter 确认；二级菜单按 0 或 q 返回，主菜单按 0 或 q 退出。普通终端也可以直接输入编号。“重新安装”和“更新 Xray”仅在已有安装时显示。操作失败会显示错误并返回菜单。

## 导入订阅

安装完成后，或通过 **节点与订阅 → 查看节点、订阅与二维码** 获取链接：

- **通用订阅**：添加到支持对应协议的客户端“订阅”功能中。
- **Clash Meta / Mihomo 订阅**：在 Clash Verge Rev 等使用 Mihomo 内核的客户端中添加远程配置。
- **Telegram**：先在“Telegram 代理”菜单安装 MTProto，再打开显示的 Telegram 链接。

导出的节点、订阅地址、`clash.yaml` 和二维码保存在：

```text
/var/lib/personal-vpn-stack/clients
```

优先使用终端显示的 HTTPS 订阅。订阅地址和二维码包含访问凭据，请勿公开。

## 端口设置

| 用途 | 默认端口 | 公网设置 |
| --- | --- | --- |
| CF 节点及 HTTPS 订阅 | 通过 Cloudflare 隧道访问 | 无需开放入站端口 |
| REALITY | TCP 43526 | 开放防火墙；NAT 机器需映射 |
| Hy2 | UDP 43526 | 启用后开放防火墙；NAT 机器需映射 |
| Telegram MTProto | TCP 53528 | 安装后开放防火墙；NAT 机器需映射 |
| 直连备用订阅 | TCP 43518 | 仅需要直连 HTTP 订阅时开放 |

TCP 与 UDP 可以使用相同端口号。REALITY、直连订阅和 MTProto 的公网 TCP 端口需要各不相同。防火墙与服务商端口映射需自行配置。

NAT 安装示例：将公网 TCP 端口 `50001` 映射到内部 `43526`，公网 UDP 端口 `50002` 映射到内部 `43526`：

```bash
bash deploy-personal-vpn.sh install --server 你的公网IP --public-port 50001 --hy2-public-port 50002
```

## 从 sing-box 切回 Xray

将服务器上的脚本替换为本版后，进入 **安装与更新 → 重新安装（保留当前配置）**，或执行：

```bash
bash deploy-personal-vpn.sh install
```

仅迁移本脚本托管、带有 `managed-by` 标记且配置有效的安装；不会接管其他脚本部署的服务。迁移保留账号、密钥、端口、Hy2 密码和证书，以及现有 TG 配置与健康监控。检查通过后才删除旧 sing-box 程序和配置；安装失败会尝试恢复文件及服务状态。

迁移前应另存配置和节点文件，迁移后重新查看订阅并在客户端验证。若临时隧道被重建，其域名可能变化。切换核心本身不能保证消除所有 CPU 高占用或外网连接问题。

## Telegram 防护与健康检查

基础节点安装完成后，进入 **Telegram 代理 → 安装 / 更新 TG 代理**。菜单会询问内部 TCP 端口和公网 TCP 端口，更新时默认保留原端口及密钥。

- **自动健康检查**随 TG 安装启用：每 60 秒检查本机 TCP 连通性和监听队列，连续 3 次异常才尝试重启，重启尝试之间至少间隔 10 分钟。手动停止的服务不会被自动拉起。
- **连接限速防护需要单独安装**：选择“安装 / 配置连接防护”。防护使用 `iptables` 和 `iptables-restore`，仅针对 TG 端口的 SYN 包，默认全端口共享每秒 25 个、突发 100 个的额度，不是每个 IP 单独计数。
- 防护规则在 TG 服务启动时恢复。规则通过一次提交更新，提交失败保留旧规则；已配置防护但规则应用失败时，会报错并阻止本次 TG 启动。状态页会检查实际入口、限速及丢弃规则，不再仅根据脚本文件存在就显示“已启用”。
- **自动校时**使用 Chrony；无调时权限或同步失败时，尝试设置 MTProto 的 30 秒时间容差。服务器时间仍需保持准确。

健康检查不验证真实 Telegram 握手，限速也不能保证抵御所有连接洪泛；安装完成后仍需用客户端验证。

## 常用命令

不带参数运行脚本即可打开菜单；也可直接执行：

```bash
# 查看订阅与节点
bash deploy-personal-vpn.sh export

# 查看服务状态 / 日志
bash deploy-personal-vpn.sh status
bash deploy-personal-vpn.sh logs

# 重启服务，保留正在运行的 Cloudflare 隧道
bash deploy-personal-vpn.sh restart

# 保留现有配置与账号，更新 Xray 至最新稳定版
bash deploy-personal-vpn.sh install --xray-version latest

# 安装或更新 TG，NAT 服务器可分别指定内部和公网端口
bash deploy-personal-vpn.sh mtproto --mtproto-port 53528 --mtproto-public-port 50003

# 单独安装 / 更新 TG 连接防护
bash deploy-personal-vpn.sh mtproto-protect

# 移除 TG 连接防护（保留 TG 服务）
bash deploy-personal-vpn.sh mtproto-unprotect

# 查看 TG 链接 / 配置自动校时
bash deploy-personal-vpn.sh mtproto-info
bash deploy-personal-vpn.sh time-sync

# 重建临时隧道，并显示新的订阅地址
bash deploy-personal-vpn.sh restart-tunnel

# 卸载（需要确认）
bash deploy-personal-vpn.sh uninstall
```

更多参数：`bash deploy-personal-vpn.sh help`。

## 常见问题

**重启后订阅失效了？**

脚本使用 Cloudflare 临时隧道。服务器重启、手动重建隧道或隧道进程重新启动后，域名可能变化。重新查看订阅，并在客户端替换旧地址。普通“重启服务”会保留正在运行的隧道。

**订阅能导入，但节点连不上？**

先在“状态与日志”查看状态和日志。REALITY 检查 TCP 放行及映射；Hy2 检查 UDP 放行及映射；CF 检查入口设置和服务器到 Cloudflare 的连通性。安装检查通过表示本机服务就绪，客户端连接仍需实际验证。

**Hy2 没有出现在订阅中？**

Hy2 可以关闭；若可选 Hy2 的下载、配置准备或启动失败，脚本会尝试跳过 Hy2 并继续安装其余服务。排查后可在“安装与更新 → 安装 / 调整节点配置”中重新启用。公共配置校验或端口冲突检查失败仍会终止安装。

**Telegram 代理无法连接？**

确认已单独安装 MTProto，检查端口放行和 NAT 映射；服务器时间不准时，可运行“配置自动校时”。在“状态与日志”查看监听队列及防护状态；若显示“已安装但未生效或无法核实”，重新安装连接防护并检查错误。仅更新基础 Xray 服务不会刷新已有的 TG 程序和启动配置，TG 更新需使用对应菜单或 `mtproto` 命令。

**停止和卸载有什么区别？**

停止保留账号和配置，之后可以重新启动。卸载会删除本脚本管理的组件，执行前需要确认。

## 配置与服务位置

| 路径 | 内容 |
| --- | --- |
| `/etc/personal-vpn-stack/` | 设置、账号、Xray / Hy2 / TG 配置及证书 |
| `/usr/local/lib/personal-vpn-stack/` | 核心程序、订阅服务与 TG 防护、健康检查脚本 |
| `/var/lib/personal-vpn-stack/clients/` | 导出的节点、订阅和二维码 |

systemd 服务：`personal-vpn-stack.service`（Xray）、`personal-vpn-stack-hy2.service`、`personal-vpn-stack-cloudflare.service`、`personal-vpn-stack-subscription.service`、`personal-vpn-stack-mtproto.service`、`personal-vpn-stack-mtproto-health.service`。Alpine 使用对应的 OpenRC 服务名，去掉 `.service` 后缀。

## 本地验证

在 Linux 环境下，准备已核验 SHA-256 的官方 Xray、Hysteria2 二进制，安装 Bash、jq、OpenSSL 及 Python 3.11+，运行：

```bash
bash -n deploy-personal-vpn.sh
shellcheck -S warning -s bash deploy-personal-vpn.sh  # 需另行安装 ShellCheck
XRAY_BINARY=/path/to/xray HYSTERIA_BINARY=/path/to/hysteria \
  python3 -m unittest discover -s tests -v
```

测试使用临时目录和模拟服务操作；协议传输使用真实核心。测试环境应允许本机 TCP / UDP 监听。未提供 Xray 路径时，部署测试会跳过，不代表完整验证通过。防火墙和 SELinux 失败场景使用模拟工具，仍需在目标系统验证真实行为。
