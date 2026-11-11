# 个人节点部署脚本

基于 **sing-box** 的个人节点部署与管理脚本，提供中文分级菜单，支持 CF 节点、REALITY、Hysteria2（Hy2）和 Telegram MTProto 代理。

首次安装使用默认端口，按提示确认地址和 Hy2 开关即可。安装后可查看订阅、修改设置、更新版本和管理服务。

## 使用条件

- 一台有 root 权限、能够访问 GitHub 和 Cloudflare 的 Linux 服务器。
- 支持 amd64 / arm64 架构。
- 系统适配：Ubuntu 20.04+、Debian 11+、CentOS 7+ / RHEL 系列（systemd），以及 Alpine（OpenRC）。建议优先使用仍受维护的系统版本。
- NAT 服务器需提前确认公网地址，以及服务商提供的 TCP / UDP 映射端口。

## 开始使用

下载本仓库的 [deploy-personal-vpn.sh](deploy-personal-vpn.sh)，上传到服务器，以 root 运行：

```bash
bash deploy-personal-vpn.sh
```

Alpine 未安装 Bash 时，运行：

```sh
sh deploy-personal-vpn.sh
```

进入 **安装与配置 → 首次安装**，按提示操作：

1. 确认服务器的公网 IP 或域名。
2. 确认 Cloudflare 入口；填写 `auto` 可使用当前隧道域名。
3. 选择是否启用 Hy2，默认启用。

直接回车即可采用方括号中的默认值，无需逐项输入端口。安装完成后，终端会显示订阅链接。

需要自定义端口时，可在安装后选择“修改地址、端口与 Hy2 设置”；首次安装到 NAT 服务器，也可使用下方命令指定映射端口。

## 菜单

```text
1. 安装与配置
   ├─ 首次安装
   └─ 保留配置重装 / 修改设置 / 更新至最新稳定版
2. 节点与订阅
   └─ 查看与导出 / 修改 CF 入口 / 重建临时隧道
3. Telegram 代理
   └─ MTProto 安装与信息 / 自动校时
4. 服务与诊断
   └─ 状态 / 日志 / 启动 / 重启 / 停止
5. 卸载全部组件
6. 退出
```

支持方向键、j/k 或数字选择，Enter 确认，0 或 q 返回。普通终端也可以直接输入编号。

## 导入订阅

安装完成后，或通过 **节点与订阅 → 查看与导出** 获取链接：

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

# 保留现有配置与账号，更新 sing-box 至最新稳定版
bash deploy-personal-vpn.sh install --sing-box-version latest

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

先在“服务与诊断”查看状态和日志。REALITY 检查 TCP 放行及映射；Hy2 检查 UDP 放行及映射；CF 检查入口设置和服务器到 Cloudflare 的连通性。安装检查通过表示本机服务就绪，客户端连接仍需实际验证。

**Hy2 没有出现在订阅中？**

Hy2 可以关闭；若安装时证书、端口或首次启动检查失败，脚本会尝试关闭 Hy2 并继续安装其余服务。排查后可在“安装与配置”中重新启用。

**Telegram 代理无法连接？**

确认已单独安装 MTProto，检查端口放行和 NAT 映射；服务器时间不准时，可运行“自动校时”。

**停止和卸载有什么区别？**

停止保留账号和配置，之后可以重新启动。卸载会删除本脚本管理的组件，执行前需要确认。
