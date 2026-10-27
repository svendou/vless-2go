#!/bin/sh
# Bootstrap Bash on Alpine; the implementation below runs only under Bash.
if [ -z "${BASH_VERSION:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    if [ "$(id -u)" != 0 ] || ! command -v apk >/dev/null 2>&1; then
      printf '%s\n' 'Bash is required. On Alpine run this script as root with sh.' >&2
      exit 1
    fi
    apk add --no-cache bash || exit 1
  fi
  exec bash "$0" "$@"
fi
# Debian/Ubuntu/CentOS 7+ + systemd, or Alpine + OpenRC.
# Contains no account credentials. Only manages the paths declared below.
set -Eeuo pipefail
umask 077

ETC_DIR=/etc/personal-vpn-stack
BIN_DIR=/usr/local/lib/personal-vpn-stack
DATA_DIR=/var/lib/personal-vpn-stack
VPN_UNIT=personal-vpn-stack.service
CF_UNIT=personal-vpn-stack-cloudflare.service
HY2_UNIT=personal-vpn-stack-hy2.service
SUB_UNIT=personal-vpn-stack-subscription.service
MT_UNIT=personal-vpn-stack-mtproto.service
SERVICE_USER=personal-vpn-stack
SERVICE_UID= SERVICE_GID=
UNIT_DIR=/etc/systemd/system
INIT_SYSTEM=systemd
PACKAGE_MANAGER=apt
DISTRO_ID= DISTRO_MAJOR= CENTOS_STREAM=0
RPM_REPO_DIR=
APT_LIST_DIR=
APT_READY=0
APT_RECOVERED=0
RPM_INSTALL_OPTS=()
RUN_DIR=/run/personal-vpn-stack
MARKER=personal-vpn-stack-v1
WORK_DIR=
INSTALL_TRANSACTION=0
FAILURE_LOG=
VPN_WAS_ACTIVE=0
CF_WAS_ACTIVE=0
HY2_WAS_ACTIVE=0
SUB_WAS_ACTIVE=0
SELINUX_RULE_ADDED=0
INTERACTIVE_INSTALL=0
SERVER_ADDR= REALITY_PORT= PUBLIC_PORT= WS_PORT= METRICS_PORT= REALITY_SNI=
CF_ENTRY= TUNNEL_PROTOCOL= XRAY_VERSION= CF_VERSION= OUTPUT_DIR=
HY2_PORT= HY2_PUBLIC_PORT= SUB_PORT= SUB_PUBLIC_PORT= HY2_VERSION= NODE_COUNTRY=
HY2_ENABLED=1
SOCKS_PORT= SOCKS_PUBLIC_PORT=
SOCKS_TRANSACTION=0
SOCKS_HAD_CONFIG=0
SOCKS_WAS_ACTIVE=0
MT_PORT= MT_PUBLIC_PORT=
MT_TRANSACTION=0
MT_WAS_ACTIVE=0
MT_WAS_ENABLED=0
MT_VPN_WAS_ACTIVE=0
MT_XRAY_CHANGED=0
MT_SELINUX_ADDED=0
MT_FILES=()
MANAGED_FILES=()

say() { printf '[vpn] %s\n' "$*"; }
die() {
  printf '[vpn] ERROR: %s\n' "$*" >&2
  if ((MT_TRANSACTION)); then rollback_mtproto; fi
  if ((SOCKS_TRANSACTION)); then rollback_socks5; fi
  if ((INSTALL_TRANSACTION)); then rollback; fi
  exit 1
}

usage() {
  cat <<'HELP'
Usage: bash deploy-personal-vpn.sh COMMAND [OPTIONS]
       sh deploy-personal-vpn.sh      # Menu; installs Bash on Alpine if needed.

Systems: Ubuntu 20.04+, Debian 11+, CentOS 7/8/Stream 8/9/10 (systemd), Alpine (OpenRC).
Python 3.6+ is required and checked after dependency installation.

Commands:
  install          Install/update Cloudflare, REALITY and subscription; try optional Hy2.
  export           Show ONE subscription URL; also save individual links and QR PNGs.
  mtproto          Install/update Telegram MTProto on TCP 53528; replaces managed SOCKS5.
  mtproto-info     Show MTProto Secret and Telegram connection link.
  time-sync        Install/enable Chrony, synchronize time and show status.
  socks5           Add/update authenticated SOCKS5 (admin, random password).
  socks5-info      Show SOCKS5 credentials and Telegram connection link.
  status           Show service state and tunnel readiness.
  restart-tunnel   Restart Quick Tunnel, then export its NEW hostname.
  set-entry        Change client entry address, then export links.
  stop             Stop this stack, including optional MTProto; keep keys and files.
  uninstall        Remove this script's installation (asks for confirmation).
  help             Show this help.

Options:
  --server HOST             Public IPv4 address or DNS name (fresh install).
  --reality-port PORT       Internal direct port (default 43526).
  --public-port PORT        Public direct port (default: same as internal).
  --ws-port PORT            Loopback WebSocket port (default 48089).
  --metrics-port PORT       Loopback health port (default 48090).
  --reality-sni HOST        REALITY handshake target (default www.cloudflare.com).
  --cf-entry HOST           Cloudflare IP/hostname, or auto (default cdns.doon.eu.org).
  --tunnel-protocol NAME    http2 (default) or quic, server-to-Cloudflare only.
  --xray-version TAG        Default v26.3.27; accepts latest.
  --cloudflared-version TAG Default 2026.10.1; accepts latest.
  --hy2-port PORT           Hy2 internal UDP port (default 43526).
  --hy2-public-port PORT    Hy2 public UDP port (default: same as internal).
  --subscription-port PORT Subscription internal TCP port (default 43518).
  --subscription-public-port PORT  Public subscription TCP port (default: internal).
  --hy2-version TAG         Default app/v2.13.0; accepts latest.
  --country CC              Node country prefix, e.g. US (default: detect automatically).
  --mtproto-port PORT       MTProto internal TCP port (default 53528).
  --mtproto-public-port PORT  MTProto public TCP port (default: internal).
  --socks-port PORT         SOCKS5 internal TCP port (default 53528; with socks5).
  --socks-public-port PORT  SOCKS5 public TCP port (default: internal; with socks5).
  --output DIR             Export directory (default under /var/lib).

Example for a NEW server, with optional public TCP 43526 mapped to internal TCP 43526:
  bash deploy-personal-vpn.sh install --server YOUR_PUBLIC_IP
  bash deploy-personal-vpn.sh set-entry --cf-entry 104.18.42.54

Quick Tunnel has a temporary hostname and no uptime guarantee.
No SSH, firewall, sysctl, or provider NAT rules are changed.
This script does not adopt the manually installed services from the chat.
HELP
}

prompt_value() {
  local variable=$1 label=$2 fallback=$3 answer
  read -r -p "$label [$fallback]：" answer || die '输入已结束。'
  printf -v "$variable" '%s' "${answer:-$fallback}"
}

arrow_menu() {
  local title=$1 footer=$2 selected=$3 index key sequence
  shift 3
  local -a labels=("$@")
  [[ -t 0 ]] || die '请在交互终端直接运行脚本，或使用 help 查看命令。'
  printf '\n'
  while :; do
    printf '\r\033[2K%s\n' "$title"
    for index in "${!labels[@]}"; do
      if ((index == selected)); then
        printf '\r\033[2K\033[1;36m  > %s\033[0m\n' "${labels[index]}"
      else
        printf '\r\033[2K    %s\n' "${labels[index]}"
      fi
    done
    printf '\r\033[2K%s\n' "$footer"
    IFS= read -rsn1 key || return 1
    case $key in
      '') break ;;
      q|Q) return 1 ;;
      $'\033')
        sequence=
        IFS= read -rsn2 -t 0.3 sequence || true
        case $sequence in
          '[A'|OA) selected=$(((selected + ${#labels[@]} - 1) % ${#labels[@]})) ;;
          '[B'|OB) selected=$(((selected + 1) % ${#labels[@]})) ;;
        esac ;;
    esac
    printf '\033[%sA' "$((${#labels[@]} + 2))"
  done
  MENU_SELECTION=$selected
}

interactive_cf_entry() {
  local current=${CF_ENTRY:-cdns.doon.eu.org} selected=0 index
  local -a entries=('cdns.doon.eu.org' 'cf.090227.xyz' 'cloudflare-ip.mofashi.ltd' 'saas.sin.fan')
  local -a labels=()
  if [[ -r "$ETC_DIR/settings.json" ]] && command -v jq >/dev/null; then
    current=$(setting cf_entry cdns.doon.eu.org)
  fi
  for index in "${!entries[@]}"; do
    labels+=("${entries[index]}:443")
    if [[ ${entries[index]} == "$current" ]]; then
      labels[index]+='（当前）'
      selected=$index
    fi
  done
  labels+=('返回主菜单')
  arrow_menu "更改 CF 入口（当前：$current:443）" '↑ / ↓ 选择，Enter 确认，q 返回' "$selected" "${labels[@]}" || return 1
  ((MENU_SELECTION < ${#entries[@]})) || return 1
  CF_ENTRY=${entries[MENU_SELECTION]}
}

interactive_menu() {
  local -a labels=('安装 / 更新（Cloudflare + Hy2）' '查看订阅链接' '更改 CF 入口' '重建临时隧道并更新订阅' '查看运行状态' '安装 / 更新 MTProto（Telegram，53528）' '查看 MTProto 连接信息' '配置自动校时（Chrony）' '卸载' '退出')
  while :; do
    arrow_menu '个人节点部署' '↑ / ↓ 选择，Enter 确认，q 退出' 0 "${labels[@]}" || return 1
    case $MENU_SELECTION in
      0) MENU_COMMAND=install; INTERACTIVE_INSTALL=1 ;;
      1) MENU_COMMAND=export ;;
      2) interactive_cf_entry || continue; MENU_COMMAND=set-entry ;;
      3) MENU_COMMAND=restart-tunnel ;;
      4) MENU_COMMAND=status ;;
      5) MENU_COMMAND=mtproto ;;
      6) MENU_COMMAND=mtproto-info ;;
      7) MENU_COMMAND=time-sync ;;
      8) MENU_COMMAND=uninstall ;;
      9) return 1 ;;
    esac
    return 0
  done
}

interactive_settings() {
  local detected=
  if [[ -z $SERVER_ADDR ]]; then
    detected=$(curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null || true)
    [[ $detected =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || detected=
    SERVER_ADDR=$detected
  fi
  printf '\n直接回车使用方括号中的默认值。NAT 机器请确认公网地址及服务商映射端口。\n'
  prompt_value SERVER_ADDR '服务器公网 IP / 域名' "$SERVER_ADDR"
  [[ -n $SERVER_ADDR ]] || die '未能识别公网地址，请重新安装时填写。'
  prompt_value REALITY_PORT '备用直连内部 TCP 端口' "$REALITY_PORT"
  if [[ ! -r "$ETC_DIR/settings.json" ]]; then PUBLIC_PORT=$REALITY_PORT; fi
  prompt_value PUBLIC_PORT '备用直连公网 TCP 端口' "$PUBLIC_PORT"
  prompt_value CF_ENTRY 'Cloudflare 入口（IP / 域名；auto 使用隧道域名）' "$CF_ENTRY"
  prompt_value HY2_PORT 'Hy2 内部 UDP 端口' "$HY2_PORT"
  if [[ ! -r "$ETC_DIR/settings.json" ]] || ! jq -e 'has("hy2_public_port")' "$ETC_DIR/settings.json" >/dev/null; then HY2_PUBLIC_PORT=$HY2_PORT; fi
  prompt_value HY2_PUBLIC_PORT 'Hy2 公网 UDP 端口' "$HY2_PUBLIC_PORT"
  prompt_value SUB_PORT '订阅内部 TCP 端口' "$SUB_PORT"
  if [[ ! -r "$ETC_DIR/settings.json" ]] || ! jq -e 'has("subscription_public_port")' "$ETC_DIR/settings.json" >/dev/null; then SUB_PUBLIC_PORT=$SUB_PORT; fi
  prompt_value SUB_PUBLIC_PORT '订阅公网 TCP 端口' "$SUB_PUBLIC_PORT"
  printf '所有设备共用一个订阅地址，包含 CF、REALITY；Hy2 安装成功时一并加入。\n\n'
}

need_root() { [[ ${EUID} -eq 0 ]] || die 'Run as root.'; }
need_installation() {
  [[ -r "$ETC_DIR/managed-by" ]] || die 'No installation managed by this script.'
  [[ $(cat "$ETC_DIR/managed-by") == "$MARKER" ]] || die 'Unrecognized installation marker.'
  [[ -r "$ETC_DIR/settings.json" && -r "$ETC_DIR/identities.json" ]] || die 'Missing settings or identities.'
}

parse_options() {
  while (($#)); do
    case "$1" in
      --server|--reality-port|--public-port|--ws-port|--metrics-port|--reality-sni|--cf-entry|--tunnel-protocol|--xray-version|--cloudflared-version|--output|--hy2-port|--hy2-public-port|--subscription-port|--subscription-public-port|--hy2-version|--country|--socks-port|--socks-public-port|--mtproto-port|--mtproto-public-port)
        (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
        case "$1" in
          --server) SERVER_ADDR=$2 ;; --reality-port) REALITY_PORT=$2 ;;
          --public-port) PUBLIC_PORT=$2 ;;
          --ws-port) WS_PORT=$2 ;; --metrics-port) METRICS_PORT=$2 ;;
          --reality-sni) REALITY_SNI=$2 ;; --cf-entry) CF_ENTRY=$2 ;;
          --tunnel-protocol) TUNNEL_PROTOCOL=$2 ;; --xray-version) XRAY_VERSION=$2 ;;
          --cloudflared-version) CF_VERSION=$2 ;; --output) OUTPUT_DIR=$2 ;;
          --hy2-port) HY2_PORT=$2 ;; --hy2-public-port) HY2_PUBLIC_PORT=$2 ;;
          --subscription-port) SUB_PORT=$2 ;; --subscription-public-port) SUB_PUBLIC_PORT=$2 ;;
          --hy2-version) HY2_VERSION=$2 ;; --country) NODE_COUNTRY=$2 ;;
          --socks-port) SOCKS_PORT=$2 ;; --socks-public-port) SOCKS_PUBLIC_PORT=$2 ;;
          --mtproto-port) MT_PORT=$2 ;; --mtproto-public-port) MT_PUBLIC_PORT=$2 ;;
        esac
        shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

setting() { jq -r --arg key "$1" --arg fallback "$2" '.[$key] // $fallback' "$ETC_DIR/settings.json"; }
load_settings() {
  if [[ -r "$ETC_DIR/settings.json" ]]; then
    SERVER_ADDR=${SERVER_ADDR:-$(setting server '')}
    REALITY_PORT=${REALITY_PORT:-$(setting reality_port 43526)}
    PUBLIC_PORT=${PUBLIC_PORT:-$(setting public_port "$REALITY_PORT")}
    WS_PORT=${WS_PORT:-$(setting ws_port 48089)}
    METRICS_PORT=${METRICS_PORT:-$(setting metrics_port 48090)}
    REALITY_SNI=${REALITY_SNI:-$(setting reality_sni www.cloudflare.com)}
    CF_ENTRY=${CF_ENTRY:-$(setting cf_entry cdns.doon.eu.org)}
    TUNNEL_PROTOCOL=${TUNNEL_PROTOCOL:-$(setting tunnel_protocol http2)}
    XRAY_VERSION=${XRAY_VERSION:-$(setting xray_version v26.3.27)}
    CF_VERSION=${CF_VERSION:-$(setting cloudflared_version 2026.10.1)}
    HY2_PORT=${HY2_PORT:-$(setting hy2_port 43526)}
    HY2_PUBLIC_PORT=${HY2_PUBLIC_PORT:-$(setting hy2_public_port "$HY2_PORT")}
    SUB_PORT=${SUB_PORT:-$(setting subscription_port 43518)}
    SUB_PUBLIC_PORT=${SUB_PUBLIC_PORT:-$(setting subscription_public_port "$SUB_PORT")}
    HY2_VERSION=${HY2_VERSION:-$(setting hy2_version app/v2.13.0)}
    NODE_COUNTRY=${NODE_COUNTRY:-$(setting node_country '')}
  fi
  REALITY_PORT=${REALITY_PORT:-43526}
  PUBLIC_PORT=${PUBLIC_PORT:-$REALITY_PORT}
  WS_PORT=${WS_PORT:-48089}
  METRICS_PORT=${METRICS_PORT:-48090}
  REALITY_SNI=${REALITY_SNI:-www.cloudflare.com}
  CF_ENTRY=${CF_ENTRY:-cdns.doon.eu.org}
  TUNNEL_PROTOCOL=${TUNNEL_PROTOCOL:-http2}
  XRAY_VERSION=${XRAY_VERSION:-v26.3.27}
  CF_VERSION=${CF_VERSION:-2026.10.1}
  HY2_PORT=${HY2_PORT:-43526}
  HY2_PUBLIC_PORT=${HY2_PUBLIC_PORT:-$HY2_PORT}
  SUB_PORT=${SUB_PORT:-43518}
  SUB_PUBLIC_PORT=${SUB_PUBLIC_PORT:-$SUB_PORT}
  HY2_VERSION=${HY2_VERSION:-app/v2.13.0}
  OUTPUT_DIR=${OUTPUT_DIR:-$DATA_DIR/clients}
}

valid_host() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && ${#1} -le 253 ]]
}
validate_settings() {
  local port
  [[ -n $SERVER_ADDR ]] && valid_host "$SERVER_ADDR" || die '--server must be a public IPv4 address or DNS name, without scheme or port.'
  valid_host "$REALITY_SNI" || die 'Invalid REALITY SNI.'
  [[ $CF_ENTRY == auto ]] || valid_host "$CF_ENTRY" || die 'Invalid Cloudflare entry; use an IPv4 address, DNS name, or auto.'
  [[ $TUNNEL_PROTOCOL == http2 || $TUNNEL_PROTOCOL == quic ]] || die 'Tunnel protocol must be http2 or quic.'
  for port in "$REALITY_PORT" "$PUBLIC_PORT" "$WS_PORT" "$METRICS_PORT" "$HY2_PORT" "$HY2_PUBLIC_PORT" "$SUB_PORT" "$SUB_PUBLIC_PORT"; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port >= 1024 && port <= 65535)) || die 'Ports must be decimal integers between 1024 and 65535.'
  done
  [[ $REALITY_PORT != "$WS_PORT" && $REALITY_PORT != "$METRICS_PORT" && $WS_PORT != "$METRICS_PORT" ]] || die 'The three listening ports must differ.'
  [[ $SUB_PORT != "$REALITY_PORT" && $SUB_PORT != "$WS_PORT" && $SUB_PORT != "$METRICS_PORT" ]] || die 'Subscription TCP port must differ from the other TCP listeners.'
  if [[ -f "$ETC_DIR/socks5.json" ]]; then
    validate_socks5_file "$ETC_DIR/socks5.json"
    validate_socks5_ports "$(jq -r .port "$ETC_DIR/socks5.json")" "$(jq -r .public_port "$ETC_DIR/socks5.json")"
  fi
  if [[ -f "$ETC_DIR/mtproto.json" ]]; then
    validate_mtproto_file "$ETC_DIR/mtproto.json"
    validate_mtproto_ports "$(jq -r .port "$ETC_DIR/mtproto.json")" "$(jq -r .public_port "$ETC_DIR/mtproto.json")"
  fi
  [[ -z $NODE_COUNTRY || $NODE_COUNTRY =~ ^[A-Z]{2}$ ]] || die '--country must be a two-letter uppercase code, e.g. US.'
  [[ $HY2_VERSION == latest || $HY2_VERSION =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die 'Invalid Hy2 release tag.'
  [[ $XRAY_VERSION =~ ^[A-Za-z0-9._-]+$ && $CF_VERSION =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid release tag.'
  [[ $OUTPUT_DIR == /* && $OUTPUT_DIR != / && $OUTPUT_DIR != *$'\n'* ]] || die '--output must be an absolute directory path.'
}

select_platform() {
  local distro=$1 like=$2 version=$3 label=${4:-} major
  DISTRO_ID=$distro
  DISTRO_MAJOR=${version%%.*}
  CENTOS_STREAM=0
  [[ $label != *Stream* ]] || CENTOS_STREAM=1
  if [[ $distro == alpine ]]; then
    PACKAGE_MANAGER=apk
    INIT_SYSTEM=openrc
    UNIT_DIR=/etc/init.d
  elif [[ $distro == debian || $distro == ubuntu || " $like " == *' debian '* ]]; then
    PACKAGE_MANAGER=apt
    INIT_SYSTEM=systemd
    UNIT_DIR=/etc/systemd/system
  elif [[ $distro == centos || $distro == rhel || $distro == rocky || $distro == almalinux || " $like " == *' rhel '* || " $like " == *' centos '* ]]; then
    major=${version%%.*}
    [[ $major =~ ^[0-9]+$ ]] && ((10#$major >= 7)) || die 'CentOS/RHEL family requires version 7 or newer.'
    PACKAGE_MANAGER=dnf
    if ((10#$major == 7)); then PACKAGE_MANAGER=yum; fi
    INIT_SYSTEM=systemd
    UNIT_DIR=/etc/systemd/system
  else
    die 'Supported systems: Debian/Ubuntu, CentOS 7+/EL 7+ with systemd, Alpine with OpenRC.'
  fi
}

check_platform() {
  [[ -r /etc/os-release ]] || die 'Missing /etc/os-release.'
  local distro like version label
  distro=$(. /etc/os-release; printf '%s' "$ID")
  like=$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")
  version=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
  label=$(. /etc/os-release; printf '%s' "${NAME:-}")
  select_platform "$distro" "$like" "$version" "$label"
  case $PACKAGE_MANAGER in
    apk)
      command -v apk >/dev/null || die 'apk not found.'
      command -v rc-service >/dev/null && [[ -d /run/openrc ]] || die 'Alpine requires a running OpenRC environment; plain Docker/chroot environments need OpenRC setup first.' ;;
    apt) command -v apt-get >/dev/null || die 'apt-get not found.' ;;
    dnf)
      if ! command -v dnf >/dev/null; then
        command -v yum >/dev/null || die 'dnf/yum not found.'
        PACKAGE_MANAGER=yum
      fi ;;
    yum) command -v yum >/dev/null || die 'yum not found.' ;;
  esac
  if [[ $INIT_SYSTEM == systemd ]]; then
    systemctl show-environment >/dev/null 2>&1 || die 'A working systemd system manager is required; plain Docker/chroot environments are not supported.'
  fi
}

selinux_active() {
  local mode
  [[ -e /sys/fs/selinux/enforce ]] && return 0
  command -v getenforce >/dev/null || return 1
  mode=$(getenforce 2>/dev/null) || return 1
  [[ $mode == Enforcing || $mode == Permissive ]]
}

centos_gpg_key() {
  local key
  if [[ $DISTRO_MAJOR == 7 ]]; then
    key=/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
    [[ -r $key ]] || die 'Missing CentOS 7 RPM signing key; restore the centos-release package keys first.'
    printf '%s\n' "$key"
  else
    for key in /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial /etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-Official; do
      if [[ -r $key ]]; then printf '%s\n' "$key"; return; fi
    done
    die 'Missing CentOS 8 RPM signing key; restore the CentOS release package keys first.'
  fi
}

prepare_legacy_centos_repos() {
  local arch root key name path
  [[ $DISTRO_ID == centos && ( $DISTRO_MAJOR == 7 || $DISTRO_MAJOR == 8 ) ]] || return 0
  [[ -z $RPM_REPO_DIR ]] || return 0
  arch=$(uname -m)
  [[ $arch == x86_64 || $arch == aarch64 ]] || die 'CentOS archive supports x86_64 and aarch64 only.'
  key=$(centos_gpg_key)
  RPM_REPO_DIR=$(mktemp -d /var/tmp/personal-vpn-repos.XXXXXXXX)
  if [[ $DISTRO_MAJOR == 7 ]]; then
    root=https://vault.centos.org/7.9.2009
    [[ $arch != aarch64 ]] || root=https://vault.centos.org/altarch/7.9.2009
    for name in os updates extras; do
      cat >> "$RPM_REPO_DIR/centos-vault.repo" <<REPO
[personal-vpn-$name]
name=Personal VPN CentOS 7 archive $name
baseurl=$root/$name/$arch/
enabled=1
gpgcheck=1
gpgkey=file://$key
sslverify=1
REPO
    done
  else
    root=https://vault.centos.org/8.5.2111
    [[ $CENTOS_STREAM != 1 ]] || root=https://vault.centos.org/8-stream
    for name in BaseOS AppStream extras; do
      path=$name/$arch/os
      cat >> "$RPM_REPO_DIR/centos-vault.repo" <<REPO
[personal-vpn-$name]
name=Personal VPN CentOS 8 archive $name
baseurl=$root/$path/
enabled=1
gpgcheck=1
gpgkey=file://$key
sslverify=1
REPO
    done
  fi
  RPM_INSTALL_OPTS=("--setopt=reposdir=$RPM_REPO_DIR" '--disablerepo=*' '--enablerepo=personal-vpn-*')
  say 'Using official CentOS Vault for this installation only; existing repository files are unchanged.'
}

rpm_install() {
  "$PACKAGE_MANAGER" "${RPM_INSTALL_OPTS[@]}" install -y "$@"
}

install_official_jq() {
  local asset digest temp_dir
  command -v jq >/dev/null && return 0
  case $(uname -m) in
    x86_64)
      asset=jq-linux-amd64; digest=020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d ;;
    aarch64)
      asset=jq-linux-arm64; digest=6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4 ;;
    *) die 'Unsupported jq architecture.' ;;
  esac
  temp_dir=$(mktemp -d /var/tmp/personal-vpn-jq.XXXXXXXX)
  if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
      "https://github.com/jqlang/jq/releases/download/jq-1.8.1/$asset" -o "$temp_dir/jq" || \
     ! printf '%s  %s\n' "$digest" "$temp_dir/jq" | sha256sum --check --status; then
    rm -rf -- "$temp_dir"
    die 'Official jq download or SHA-256 validation failed.'
  fi
  chmod 0755 "$temp_dir/jq"
  if ! "$temp_dir/jq" --version; then rm -rf -- "$temp_dir"; die 'Official jq binary cannot run on this server.'; fi
  [[ ! -e /usr/local/bin/jq && ! -L /usr/local/bin/jq ]] || { rm -rf -- "$temp_dir"; die 'Refusing to replace an existing /usr/local/bin/jq.'; }
  install -d -m 0755 /usr/local/bin
  install -m 0755 "$temp_dir/jq" /usr/local/bin/jq
  rm -rf -- "$temp_dir"
  export PATH="/usr/local/bin:$PATH"
  hash -r
}

# Request fresh metadata without changing the machine's repository configuration.
# A broken mirror/proxy can still return old metadata: recover once with a
# separate lists directory so an unsuccessful refresh cannot reuse old lists.
apt_refresh() {
  local -a options=(
    -o Acquire::Retries=2
    -o Acquire::http::No-Cache=true
    -o Acquire::https::No-Cache=true
    -o APT::Update::Error-Mode=any
  )
  if [[ -n $APT_LIST_DIR ]]; then
    options+=(-o "Dir::State::lists=$APT_LIST_DIR" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
  fi
  apt-get "${options[@]}" update || return $?
}

apt_install_once() {
  local -a options=(
    -o Acquire::Retries=2
    -o Acquire::http::No-Cache=true
    -o Acquire::https::No-Cache=true
  )
  if [[ -n $APT_LIST_DIR ]]; then
    options+=(-o "Dir::State::lists=$APT_LIST_DIR" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
  fi
  DEBIAN_FRONTEND=noninteractive apt-get "${options[@]}" install -y --no-install-recommends --no-upgrade "$@" || return $?
}

apt_install_packages() {
  if (( !APT_READY )); then
    if apt_refresh; then APT_READY=1; fi
  fi
  if ((APT_READY)) && apt_install_once "$@"; then return 0; fi
  if ((APT_RECOVERED)); then
    say 'APT still failed. Check the configured repositories, proxy/cache and mirror availability; repository files were not changed.'
    return 1
  fi
  APT_RECOVERED=1
  say 'APT 更新或下载失败；使用独立新索引重试一次，绕过可复用的旧索引和 HTTP 缓存。'
  APT_LIST_DIR=$(mktemp -d /var/tmp/personal-vpn-apt-lists.XXXXXXXX) || return 1
  # The _apt sandbox user must be able to traverse the temporary lists directory.
  chmod 0755 "$APT_LIST_DIR" || return 1
  mkdir -p "$APT_LIST_DIR/partial" || return 1
  if apt_refresh; then
    APT_READY=1
    if apt_install_once "$@"; then return 0; fi
  fi
  say 'APT 重试仍失败。请检查软件源、缓存代理或镜像同步状态；未自动更换发行版、归档源或关闭签名验证。'
  return 1
}

has_ca_bundle() {
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]]
}

apt_install_prerequisites() {
  local cmd
  if apt_install_packages "$@"; then return 0; fi
  # APT can fail solely on jq/libjq1 while all other tools are already usable.
  # Only that case may use the verified standalone jq; missing tools still fail.
  if command -v jq >/dev/null; then return 1; fi
  for cmd in curl unzip tar gzip openssl setpriv flock ss useradd groupadd userdel groupdel getent install python3 sha256sum; do
    command -v "$cmd" >/dev/null || return 1
  done
  has_ca_bundle || return 1
  say '其他必需工具齐全，仅缺少 jq；改用 jq 官方固定版本并校验 SHA-256。系统 APT 软件源问题仍需另行处理。'
  install_official_jq
}

install_dependencies() {
  local missing=0 cmd
  local -a rpm_packages
  prepare_legacy_centos_repos
  for cmd in curl unzip tar gzip openssl jq setpriv flock ss useradd groupadd userdel groupdel getent install python3; do
    command -v "$cmd" >/dev/null || missing=1
  done
  has_ca_bundle || missing=1
  if selinux_active; then
    for cmd in semanage restorecon; do command -v "$cmd" >/dev/null || missing=1; done
  fi
  if ((missing)); then
    say 'Installing small prerequisite packages.'
    if [[ $PACKAGE_MANAGER == apk ]]; then
      apk add --no-cache bash ca-certificates curl unzip tar gzip openssl jq setpriv flock \
        iproute2 shadow coreutils python3
    elif [[ $PACKAGE_MANAGER == dnf || $PACKAGE_MANAGER == yum ]]; then
      rpm_packages=(ca-certificates unzip tar gzip openssl util-linux iproute shadow-utils coreutils glibc-common python3)
      if [[ $DISTRO_MAJOR != 7 ]]; then rpm_packages+=(jq); fi
      # Retain a working curl-minimal instead of conflicting with it by installing curl.
      if ! command -v curl >/dev/null; then rpm_packages+=(curl); fi
      if selinux_active; then
        rpm_packages+=(policycoreutils)
        if [[ $DISTRO_MAJOR == 7 ]]; then rpm_packages+=(policycoreutils-python)
        else rpm_packages+=(policycoreutils-python-utils); fi
      fi
      rpm_install "${rpm_packages[@]}"
    else
      apt_install_prerequisites \
        ca-certificates curl unzip tar gzip openssl jq util-linux iproute2 passwd coreutils python3 \
        || die 'Dependency installation failed; inspect the APT error above, repair the repository/cache, then retry.' 
      if selinux_active; then
        apt_install_packages policycoreutils policycoreutils-python-utils || die 'SELinux dependency installation failed.'
      fi
    fi
  fi
  if [[ ( $PACKAGE_MANAGER == dnf || $PACKAGE_MANAGER == yum ) && $DISTRO_MAJOR == 7 ]]; then install_official_jq; fi
  # QR encoding is optional; never enable EPEL just to install it.
  if ! command -v qrencode >/dev/null; then
    case $PACKAGE_MANAGER in
      apk) apk add --no-cache libqrencode-tools || say 'QR package unavailable; subscription links will still be exported.' ;;
      dnf|yum) rpm_install qrencode || say 'QR package unavailable; subscription links will still be exported.' ;;
      apt) apt_install_packages qrencode || say 'QR package unavailable; subscription links will still be exported.' ;;
    esac
  fi
  for cmd in curl unzip tar gzip openssl jq setpriv flock ss useradd groupadd userdel groupdel getent install python3; do
    command -v "$cmd" >/dev/null || die "Required command unavailable after dependency installation: $cmd"
  done
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' || die 'Python 3.6+ is required; the system Python 2 is not used or replaced.'
}

apply_selinux_contexts() {
  local pattern="$BIN_DIR/(xray|cloudflared|hysteria)"
  local -a executables=("$BIN_DIR/xray" "$BIN_DIR/cloudflared")
  selinux_active || return 0
  command -v semanage >/dev/null && command -v restorecon >/dev/null || die 'SELinux requires semanage and restorecon; install the distribution policycoreutils Python utilities.'
  if [[ -f "$ETC_DIR/selinux-fcontext" ]]; then
    [[ $(cat "$ETC_DIR/selinux-fcontext") == "$pattern" ]] || die 'Unexpected managed SELinux label rule.'
    semanage fcontext -m -t bin_t "$pattern"
  else
    # Never replace a pre-existing custom rule that this script does not own.
    semanage fcontext -a -t bin_t "$pattern" || die 'Cannot add the managed SELinux label rule; check existing custom fcontext rules.'
    SELINUX_RULE_ADDED=1
    printf '%s\n' "$pattern" > "$ETC_DIR/selinux-fcontext"
    chmod 0600 "$ETC_DIR/selinux-fcontext"
  fi
  [[ ! -f "$BIN_DIR/hysteria" ]] || executables+=("$BIN_DIR/hysteria")
  restorecon -F "${executables[@]}"
}

remove_selinux_contexts() {
  local pattern="$BIN_DIR/(xray|cloudflared|hysteria)"
  [[ -f "$ETC_DIR/selinux-fcontext" ]] || return 0
  [[ $(cat "$ETC_DIR/selinux-fcontext") == "$pattern" ]] || die 'Unexpected managed SELinux label rule.'
  command -v semanage >/dev/null || die 'semanage is required to remove the managed SELinux label rule.'
  semanage fcontext -d "$pattern"
}

service_file() {
  if [[ $INIT_SYSTEM == openrc ]]; then printf '%s/%s\n' "$UNIT_DIR" "${1%.service}"
  else printf '%s/%s\n' "$UNIT_DIR" "$1"; fi
}

svc() (
  # Keep the caller's lock, but do not let OpenRC daemons inherit its descriptor.
  exec 9>&-
  local action=$1 unit name
  shift
  if [[ $INIT_SYSTEM == systemd ]]; then
    case $action in
      is-active) systemctl is-active --quiet "$@" ;;
      reload) systemctl daemon-reload ;;
      status) systemctl show "$@" -p Id -p ActiveState -p NRestarts ;;
      *) systemctl "$action" "$@" ;;
    esac
    return
  fi
  case $action in reload|reset-failed) return 0 ;; esac
  for unit in "$@"; do
    name=${unit%.service}
    case $action in
      is-active) rc-service "$name" status >/dev/null 2>&1 || return $? ;;
      start) rc-service "$name" status >/dev/null 2>&1 || rc-service "$name" start || return $? ;;
      stop) if rc-service "$name" status >/dev/null 2>&1; then rc-service "$name" stop || return $?; fi ;;
      restart) rc-service "$name" restart || return $? ;;
      enable) rc-update add "$name" default || return $? ;;
      disable)
        if [[ -L /etc/runlevels/default/$name ]]; then
          rc-update del "$name" default || return $?
        fi ;;
      status) rc-service "$name" status || true ;;
      *) die "Unsupported service operation: $action" ;;
    esac
  done
)

tunnel_logs() {
  if [[ $INIT_SYSTEM == openrc ]]; then
    [[ ! -r "$RUN_DIR/cloudflare.log" ]] || tail -n 15 "$RUN_DIR/cloudflare.log" >&2
  else
    journalctl -u "$CF_UNIT" -n 15 --no-pager >&2 || true
  fi
}

restart_service() {
  local unit=$1 code
  # Keep the service manager's own message, even if the application never runs.
  if svc restart "$unit" 2>&1 | tee "$WORK_DIR/start-${unit%.service}.log"; then
    return 0
  else
    code=$?
    return "$code"
  fi
}

collect_failure_diagnostics() {
  local file
  [[ -n $WORK_DIR && -d $WORK_DIR ]] || return 0
  FAILURE_LOG=$(mktemp /var/tmp/personal-vpn-stack-failure.XXXXXXXX.log) || return 0
  chmod 0600 "$FAILURE_LOG"
  {
    printf 'Service manager: %s\n' "$INIT_SYSTEM"
    for file in "$WORK_DIR"/start-*.log "$WORK_DIR"/optional-hy2-*.log "$WORK_DIR/certificate-generation.log"; do
      if [[ -f $file ]]; then
        printf '\nInstallation step output: %s\n' "${file##*/}"
        cat "$file"
      fi
    done
    if [[ $INIT_SYSTEM == openrc ]]; then
      rc-status 2>&1 || true
      for file in "$RUN_DIR/xray.log" "$RUN_DIR/cloudflare.log" "$RUN_DIR/hy2.log" "$RUN_DIR/subscription.log"; do
        printf '\nApplication log: %s\n' "$file"
        if [[ -r $file ]]; then tail -n 40 "$file"; else printf 'Not created.\n'; fi
      done
    else
      journalctl -u "$VPN_UNIT" -u "$CF_UNIT" -u "$HY2_UNIT" -u "$SUB_UNIT" -n 40 --no-pager 2>&1 || true
    fi
  } > "$FAILURE_LOG" 2>&1
  cat "$FAILURE_LOG" >&2
  say "Failure details retained at: $FAILURE_LOG"
}

make_workdir() {
  mkdir -p /var/tmp
  WORK_DIR=$(mktemp -d /var/tmp/personal-vpn-stack.XXXXXXXX)
  chmod 0700 "$WORK_DIR"
}
cleanup() {
  if [[ -n $APT_LIST_DIR && $APT_LIST_DIR == /var/tmp/personal-vpn-apt-lists.* ]]; then
    rm -rf -- "$APT_LIST_DIR"
  fi
  if [[ -n $RPM_REPO_DIR && $RPM_REPO_DIR == /var/tmp/personal-vpn-repos.* ]]; then
    rm -rf -- "$RPM_REPO_DIR"
  fi
  if [[ -n $WORK_DIR && $WORK_DIR == /var/tmp/personal-vpn-stack.* ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

download_asset() {
  local repo=$1 tag=$2 asset=$3 destination=$4 endpoint metadata asset_json url digest expected
  if [[ $tag == latest ]]; then endpoint=latest; else endpoint="tags/$tag"; fi
  metadata="$WORK_DIR/$(basename "$destination").release.json"
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
    -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/releases/$endpoint" -o "$metadata" || return 1
  asset_json=$(jq -ce --arg name "$asset" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else error("asset not found") end' "$metadata") || return 1
  url=$(jq -er '.browser_download_url' <<<"$asset_json") || return 1
  digest=$(jq -r '.digest // empty' <<<"$asset_json") || return 1
  [[ $url == https://github.com/* ]] || die 'Unexpected release download URL.'
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 "$url" -o "$destination" || return 1
  if [[ $digest =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
    expected=${BASH_REMATCH[1]}
  elif [[ $repo == XTLS/Xray-core ]]; then
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "$url.dgst" -o "$destination.dgst" || return 1
    expected=$(awk '/^SHA2-256=/{print $2}' "$destination.dgst")
  else
    die 'No official SHA-256 digest found; refusing unverified installation.'
  fi
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die 'Invalid release digest.'
  printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status || die 'Download checksum mismatch.'
  RESOLVED_TAG=$(jq -er '.tag_name' "$metadata")
}

stage_binaries() {
  local xray_asset cf_asset
  case $(uname -m) in
    x86_64|amd64) xray_asset=Xray-linux-64.zip; cf_asset=cloudflared-linux-amd64 ;;
    aarch64|arm64) xray_asset=Xray-linux-arm64-v8a.zip; cf_asset=cloudflared-linux-arm64 ;;
    *) die 'Supported architectures: amd64 and arm64.' ;;
  esac
  say 'Downloading official releases and verifying SHA-256.'
  download_asset XTLS/Xray-core "$XRAY_VERSION" "$xray_asset" "$WORK_DIR/xray.zip"
  XRAY_VERSION=$RESOLVED_TAG
  unzip -oq "$WORK_DIR/xray.zip" xray -d "$WORK_DIR"
  chmod 0755 "$WORK_DIR/xray"
  "$WORK_DIR/xray" version
  download_asset cloudflare/cloudflared "$CF_VERSION" "$cf_asset" "$WORK_DIR/cloudflared"
  CF_VERSION=$RESOLVED_TAG
  chmod 0755 "$WORK_DIR/cloudflared"
  "$WORK_DIR/cloudflared" --version
}

stage_hy2_binary() {
  local asset
  case $(uname -m) in
    x86_64|amd64) asset=hysteria-linux-amd64 ;;
    aarch64|arm64) asset=hysteria-linux-arm64 ;;
    *) return 1 ;;
  esac
  download_asset apernet/hysteria "$HY2_VERSION" "$asset" "$WORK_DIR/hysteria" || return 1
  chmod 0755 "$WORK_DIR/hysteria" || return 1
  "$WORK_DIR/hysteria" version || return 1
  printf '%s\n' "$RESOLVED_TAG" > "$WORK_DIR/hy2-version"
}

attempt_hy2() {
  local step=$1 saved_log
  shift
  # Optional helpers explicitly check every command: conditional calls in Bash
  # suppress errexit. A failure here must never invoke the global rollback.
  if (INSTALL_TRANSACTION=0; trap - ERR; "$@") > "$WORK_DIR/optional-hy2-$step.log" 2>&1; then
    return 0
  fi
  cat "$WORK_DIR/optional-hy2-$step.log" >&2
  saved_log=$(mktemp /var/tmp/personal-vpn-stack-hy2-failure.XXXXXXXX.log) || saved_log=
  if [[ -n $saved_log ]]; then
    chmod 0600 "$saved_log" && cp "$WORK_DIR/optional-hy2-$step.log" "$saved_log" || true
    say "Hy2 failure details: $saved_log"
  fi
  return 1
}

skip_hy2() {
  HY2_ENABLED=0
  say 'WARNING: Hy2 安装或启动失败，已跳过；继续安装 Cloudflare、REALITY 和订阅服务。'
  if [[ -f $(service_file "$HY2_UNIT") ]]; then
    svc stop "$HY2_UNIT" >/dev/null 2>&1 || true
    svc disable "$HY2_UNIT" >/dev/null 2>&1 || true
    svc reset-failed "$HY2_UNIT" >/dev/null 2>&1 || true
  fi
}

prepare_hy2() {
  install -m 0755 "$WORK_DIR/hysteria" "$BIN_DIR/hysteria" || return 1
  ensure_hy2_certificate || return 1
  render_hy2_config || return 1
}

start_hy2() {
  restart_service "$HY2_UNIT" || return 1
  wait_hy2 || return 1
  svc enable "$HY2_UNIT" || return 1
}

check_ports() {
  local port key old_port owner
  if [[ -f "$ETC_DIR/socks5.json" ]]; then
    check_socks5_port "$(jq -r .port "$ETC_DIR/socks5.json")"
  fi
  for key in reality_port ws_port metrics_port subscription_port; do
    case $key in reality_port) port=$REALITY_PORT ;; ws_port) port=$WS_PORT ;; metrics_port) port=$METRICS_PORT ;; subscription_port) port=$SUB_PORT ;; esac
    if ss -H -ltn "sport = :$port" | grep -q .; then
      old_port=
      [[ ! -r "$ETC_DIR/settings.json" ]] || old_port=$(setting "$key" '')
      case $key in metrics_port) owner=$CF_UNIT ;; subscription_port) owner=$SUB_UNIT ;; *) owner=$VPN_UNIT ;; esac
      if [[ $port != "$old_port" ]] || ! svc is-active "$owner"; then
        die "TCP port $port is occupied by another service. Choose unused ports; existing services were not changed."
      fi
    fi
  done
  if ss -H -lun "sport = :$HY2_PORT" | grep -q .; then
    old_port=
    [[ ! -r "$ETC_DIR/settings.json" ]] || old_port=$(setting hy2_port '')
    if [[ $HY2_PORT != "$old_port" ]] || ! svc is-active "$HY2_UNIT"; then
      HY2_ENABLED=0
      say "WARNING: UDP $HY2_PORT 已被其他服务占用，跳过 Hy2，保留其他节点。"
    fi
  fi
}

backup_managed_files() {
  local file
  MANAGED_FILES=("$BIN_DIR/xray" "$BIN_DIR/cloudflared" "$BIN_DIR/hysteria" "$BIN_DIR/subscription.py" \
    "$ETC_DIR/settings.json" "$ETC_DIR/identities.json" "$ETC_DIR/xray.json" \
    "$ETC_DIR/socks5.json" "$ETC_DIR/hy2.json" "$ETC_DIR/hy2.crt" "$ETC_DIR/hy2.key" "$ETC_DIR/subscription.json" "$ETC_DIR/selinux-fcontext" \
    "$(service_file "$VPN_UNIT")" "$(service_file "$CF_UNIT")" "$(service_file "$HY2_UNIT")" "$(service_file "$SUB_UNIT")")
  mkdir -p "$WORK_DIR/backup"
  for file in "${MANAGED_FILES[@]}"; do
    [[ ! -e $file ]] || cp -a --parents "$file" "$WORK_DIR/backup"
  done
  if svc is-active "$VPN_UNIT"; then VPN_WAS_ACTIVE=1; fi
  if svc is-active "$CF_UNIT"; then CF_WAS_ACTIVE=1; fi
  if svc is-active "$HY2_UNIT"; then HY2_WAS_ACTIVE=1; fi
  if svc is-active "$SUB_UNIT"; then SUB_WAS_ACTIVE=1; fi
  INSTALL_TRANSACTION=1
}

rollback() {
  local file
  ((INSTALL_TRANSACTION)) || return 0
  INSTALL_TRANSACTION=0
  say "Installation failed; restoring only this script's managed files."
  if ((SELINUX_RULE_ADDED)); then
    semanage fcontext -d "$BIN_DIR/(xray|cloudflared|hysteria)" || say 'Could not remove the new SELinux label rule during rollback.'
    SELINUX_RULE_ADDED=0
  fi
  svc stop "$SUB_UNIT" "$HY2_UNIT" "$CF_UNIT" "$VPN_UNIT" >/dev/null 2>&1 || true
  # Fresh installs must not leave runlevel symlinks for services rolled back away.
  for file in "$VPN_UNIT" "$CF_UNIT" "$HY2_UNIT" "$SUB_UNIT"; do
    if [[ ! -e "$WORK_DIR/backup$(service_file "$file")" ]]; then svc disable "$file" >/dev/null 2>&1 || true; fi
  done
  for file in "${MANAGED_FILES[@]}"; do
    if [[ -e "$WORK_DIR/backup$file" ]]; then
      cp -a "$WORK_DIR/backup$file" "$file" || true
    else
      rm -f -- "$file" || true
    fi
  done
  svc reload || true
  if ((VPN_WAS_ACTIVE)); then svc start "$VPN_UNIT" || true; fi
  if ((CF_WAS_ACTIVE)); then svc start "$CF_UNIT" || true; fi
  if ((HY2_WAS_ACTIVE)); then svc start "$HY2_UNIT" || true; fi
  if ((SUB_WAS_ACTIVE)); then svc start "$SUB_UNIT" || true; fi
  say 'Restarted Quick Tunnels may have a different hostname; export links again after recovery.'
}

on_error() {
  local code=$1 line=$2
  trap - ERR
  set +e
  printf '[vpn] Failed near line %s (exit %s).\n' "$line" "$code" >&2
  if ((INSTALL_TRANSACTION)); then collect_failure_diagnostics; fi
  rollback_mtproto
  rollback_socks5
  rollback
  exit "$code"
}

ensure_user() {
  local nologin_shell
  nologin_shell=$(command -v nologin || printf /bin/false)
  getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
  id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --gid "$SERVICE_USER" --no-create-home --shell "$nologin_shell" "$SERVICE_USER"
  [[ $(id -u "$SERVICE_USER") -ne 0 && $(id -gn "$SERVICE_USER") == "$SERVICE_USER" ]] || die 'Unexpected service user identity.'
}

ensure_identities() {
  local output private public uuid migrated
  if [[ -r "$ETC_DIR/identities.json" ]]; then
    jq -e '(.schema == 1 or .schema == 2) and (.private_key | length > 0) and (.public_key | length > 0) and (.ws_path | startswith("/cf-")) and ((.account // .devices.windows) | .direct and .cloudflare)' "$ETC_DIR/identities.json" >/dev/null
    if jq -e '.schema == 1' "$ETC_DIR/identities.json" >/dev/null; then
      migrated=$(mktemp "$ETC_DIR/.identities.XXXXXXXX")
      jq '.schema = 2 | .account = .devices.windows | del(.devices)' "$ETC_DIR/identities.json" > "$migrated"
      chmod 0600 "$migrated"
      mv -f -- "$migrated" "$ETC_DIR/identities.json"
      say 'Shared account retains previous Windows links; reimport these links on other devices.'
    fi
    if ! jq -e '(.hy2_password | type == "string" and length >= 32) and (.subscription_token | type == "string" and test("^[a-f0-9]{48}$"))' "$ETC_DIR/identities.json" >/dev/null; then
      migrated=$(mktemp "$ETC_DIR/.identities.XXXXXXXX")
      jq --arg password "$(openssl rand -hex 24)" --arg token "$(openssl rand -hex 24)" \
        '.hy2_password = (.hy2_password // $password) | .subscription_token = (.subscription_token // $token)' \
        "$ETC_DIR/identities.json" > "$migrated"
      chmod 0600 "$migrated"
      mv -f -- "$migrated" "$ETC_DIR/identities.json"
    fi
    return
  fi
  output=$("$BIN_DIR/xray" x25519)
  private=$(awk '/^PrivateKey:/{print $NF}' <<<"$output")
  public=$(awk '/^(Password|PublicKey)/{print $NF;exit}' <<<"$output")
  [[ -n $private && -n $public ]] || die 'Unrecognized x25519 output.'
  uuid=$("$BIN_DIR/xray" uuid)
  jq -n --arg private "$private" --arg public "$public" --arg sid "$(openssl rand -hex 8)" \
    --arg path "/cf-$(openssl rand -hex 12)" \
    --arg uuid "$uuid" --arg hp "$(openssl rand -hex 24)" --arg token "$(openssl rand -hex 24)" \
    '{schema:2,private_key:$private,public_key:$public,short_id:$sid,ws_path:$path,
      account:{direct:$uuid,cloudflare:$uuid},hy2_password:$hp,subscription_token:$token}' \
    > "$ETC_DIR/identities.json"
  chmod 0600 "$ETC_DIR/identities.json"
}

detect_node_country() {
  [[ -z $NODE_COUNTRY ]] || return 0
  NODE_COUNTRY=$(curl -4fsS --connect-timeout 3 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=\([A-Z][A-Z]\)\r\{0,1\}$/\1/p' | head -n 1) || NODE_COUNTRY=
  [[ $NODE_COUNTRY =~ ^[A-Z]{2}$ ]] || NODE_COUNTRY=
}

write_settings() {
  jq -n --arg server "$SERVER_ADDR" --argjson rp "$REALITY_PORT" --argjson pp "$PUBLIC_PORT" --argjson wp "$WS_PORT" \
    --argjson mp "$METRICS_PORT" --arg sni "$REALITY_SNI" --arg entry "$CF_ENTRY" \
    --arg protocol "$TUNNEL_PROTOCOL" --arg xv "$XRAY_VERSION" --arg cv "$CF_VERSION" \
    --argjson hp "$HY2_PORT" --argjson hpp "$HY2_PUBLIC_PORT" --argjson sp "$SUB_PORT" --argjson spp "$SUB_PUBLIC_PORT" \
    --arg hv "$HY2_VERSION" --arg country "$NODE_COUNTRY" --argjson he "$HY2_ENABLED" \
    '{schema:1,server:$server,reality_port:$rp,public_port:$pp,ws_port:$wp,metrics_port:$mp,reality_sni:$sni,
      cf_entry:$entry,tunnel_protocol:$protocol,xray_version:$xv,cloudflared_version:$cv,
      hy2_port:$hp,hy2_public_port:$hpp,subscription_port:$sp,subscription_public_port:$spp,hy2_version:$hv,node_country:$country,hy2_enabled:($he==1)}' \
    > "$ETC_DIR/settings.json"
  chmod 0600 "$ETC_DIR/settings.json"
}

ensure_hy2_certificate() {
  local cert_temp cert_log
  if [[ ! -f "$ETC_DIR/hy2.crt" || ! -f "$ETC_DIR/hy2.key" ]] || \
      openssl x509 -in "$ETC_DIR/hy2.crt" -noout -text | grep -q 'Field Type:'; then
    cert_temp=$(mktemp -d "$ETC_DIR/.hy2-cert.XXXXXXXX") || return 1
    cert_log="$cert_temp/openssl.log"
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then cert_log="$WORK_DIR/certificate-generation.log"; fi
    # OpenSSL 1.0.2 (CentOS 7) has no req -addext; config extensions work on all supported versions.
    cat > "$cert_temp/openssl.cnf" <<'OPENSSL_CONFIG' || return 1
[req]
prompt = no
distinguished_name = subject
x509_extensions = server_cert
[subject]
CN = hy2.local
[server_cert]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:hy2.local
OPENSSL_CONFIG
    openssl version > "$cert_log" 2>&1 || true
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve -nodes -sha256 -days 3650 \
        -config "$cert_temp/openssl.cnf" -extensions server_cert \
        -keyout "$cert_temp/hy2.key" -out "$cert_temp/hy2.crt" >> "$cert_log" 2>&1; then
      if ((INSTALL_TRANSACTION)) && [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        collect_failure_diagnostics
      else
        cat "$cert_log" >&2
      fi
      rm -rf -- "$cert_temp"
      die 'Hy2 certificate generation failed; OpenSSL details are shown above.'
    fi
    mv -f -- "$cert_temp/hy2.key" "$ETC_DIR/hy2.key" || return 1
    mv -f -- "$cert_temp/hy2.crt" "$ETC_DIR/hy2.crt" || return 1
    rm -rf -- "$cert_temp" || return 1
  fi
  openssl x509 -in "$ETC_DIR/hy2.crt" -noout -checkend 0 >/dev/null || die 'Hy2 certificate has expired.'
  [[ $(openssl x509 -in "$ETC_DIR/hy2.crt" -pubkey -noout | openssl sha256) == \
     $(openssl pkey -in "$ETC_DIR/hy2.key" -pubout | openssl sha256) ]] || die 'Hy2 certificate/key mismatch.'
  chown root:"$SERVICE_USER" "$ETC_DIR/hy2.crt" "$ETC_DIR/hy2.key" || return 1
  chmod 0640 "$ETC_DIR/hy2.crt" "$ETC_DIR/hy2.key"
}

render_hy2_config() {
  jq --arg listen "0.0.0.0:$HY2_PORT" --arg cert "$ETC_DIR/hy2.crt" --arg key "$ETC_DIR/hy2.key" \
    '{listen:$listen,tls:{cert:$cert,key:$key},auth:{type:"password",password:.hy2_password}}' \
    "$ETC_DIR/identities.json" > "$ETC_DIR/hy2.json" || return 1
  chown root:"$SERVICE_USER" "$ETC_DIR/hy2.json" || return 1
  chmod 0640 "$ETC_DIR/hy2.json"
}

write_subscription_config() {
  local pin= file
  if jq -e '.hy2_enabled != false' "$ETC_DIR/settings.json" >/dev/null; then
    pin=$(openssl x509 -in "$ETC_DIR/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':\r\n' | tr 'A-F' 'a-f')
    [[ $pin =~ ^[a-f0-9]{64}$ ]] || die 'Invalid Hy2 certificate fingerprint.'
  fi
  file=$(mktemp "$ETC_DIR/.subscription.XXXXXXXX")
  jq -s --arg pin "$pin" --arg logs "$RUN_DIR/cloudflare.log" \
    '.[0] + {identities:.[1],hy2_pin:$pin,cf_log:$logs,subscription_https:true}' \
    "$ETC_DIR/settings.json" "$ETC_DIR/identities.json" > "$file"
  chown root:"$SERVICE_USER" "$file"
  chmod 0640 "$file"
  mv -f -- "$file" "$ETC_DIR/subscription.json"
}

render_subscription_server() {
  cat > "$BIN_DIR/subscription.py" <<'SUBSCRIPTION_PY'
"""Private subscription endpoint. Embedded by the single-file installer."""
import argparse
import base64
import hmac
import json
import re
import selectors
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
try:
    from http.server import ThreadingHTTPServer
except ImportError:
    # CentOS 7/8 provide Python 3.6; this class entered the stdlib in 3.7.
    from socketserver import ThreadingMixIn

    class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True
from pathlib import Path
from urllib.parse import quote, urlencode, urlsplit


def load_config(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def current_domain(cfg, fallback=""):
    try:
        log = Path(cfg["cf_log"])
        # Read only the tail, including if the tunnel log grows for months.
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - 131072))
            matches = re.findall(rb"https://([a-z0-9-]+\.trycloudflare\.com)", stream.read())
        if matches:
            return matches[-1].decode("ascii")
    except OSError:
        pass
    return fallback


def nodes(cfg, domain):
    ids = cfg["identities"]
    account = ids.get("account") or ids["devices"]["windows"]
    prefix = cfg.get("node_country") or cfg["server"]
    result = {}
    if domain:
        entry = cfg["cf_entry"] if cfg["cf_entry"] != "auto" else domain
        params = {"encryption": "none", "security": "tls", "sni": domain, "fp": "chrome",
                  "alpn": "http/1.1", "type": "ws", "host": domain, "path": ids["ws_path"]}
        result["CF"] = f'vless://{account["cloudflare"]}@{entry}:443?{urlencode(params)}#{quote(prefix + "-CF", safe="")}'
    if cfg.get("hy2_enabled", True):
        params = {"sni": "hy2.local", "insecure": "1", "pinSHA256": cfg["hy2_pin"]}
        result["Hy2"] = (f'hysteria2://{quote(ids["hy2_password"], safe="")}@{cfg["server"]}:'
                         f'{cfg["hy2_public_port"]}/?{urlencode(params)}#{quote(prefix + "-Hy2", safe="")}')
    params = {"encryption": "none", "security": "reality", "sni": cfg["reality_sni"],
              "fp": "chrome", "pbk": ids["public_key"], "sid": ids["short_id"],
              "type": "tcp", "flow": "xtls-rprx-vision"}
    result["REALITY"] = (f'vless://{account["direct"]}@{cfg["server"]}:{cfg["public_port"]}'
                         f'?{urlencode(params)}#{quote(prefix + "-REALITY", safe="")}')
    return result


def subscription_url(cfg, domain="", direct=False):
    if domain and cfg.get("subscription_https") and not direct:
        return f'https://{domain}/{cfg["identities"]["subscription_token"]}'
    return f'http://{cfg["server"]}:{cfg["subscription_public_port"]}/{cfg["identities"]["subscription_token"]}'


def payload(cfg, domain):
    return base64.b64encode(("\n".join(nodes(cfg, domain).values()) + "\n").encode("utf-8"))


class SubscriptionHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # The relay reads the socket directly: never buffer early WebSocket frames.
    rbufsize = 0

    def do_GET(self):
        self.respond(False)

    def do_HEAD(self):
        self.respond(True)

    def respond(self, head_only):
        try:
            cfg = load_config(self.server.config_path)
            if (not head_only and urlsplit(self.path).path == cfg["identities"]["ws_path"]
                    and self.headers.get("Upgrade", "").lower() == "websocket"
                    and "upgrade" in [item.strip() for item in self.headers.get("Connection", "").lower().split(",")]):
                self.proxy_websocket(cfg)
                return
            expected = "/" + cfg["identities"]["subscription_token"]
            if not hmac.compare_digest(urlsplit(self.path).path.encode(), expected.encode()):
                self.send_body(404, b"Not Found\n", head_only)
                return
            self.send_body(200, payload(cfg, current_domain(cfg)), head_only)
        except (OSError, ValueError, KeyError):
            self.send_body(503, b"Temporarily unavailable\n", head_only)

    def proxy_websocket(self, cfg):
        # Only this configured path can reach the fixed loopback Xray endpoint.
        self.close_connection = True
        try:
            upstream = socket.create_connection(("127.0.0.1", int(cfg["ws_port"])), timeout=10)
        except OSError:
            self.send_body(502, b"Upstream unavailable\n", False)
            return
        with upstream:
            try:
                headers = list(self.headers.items())
                if any("\r" in value or "\n" in value for _, value in headers):
                    self.send_body(400, b"Invalid headers\n", False)
                    return
                request = f"GET {self.path} HTTP/1.1\r\n" + "".join(
                    f"{name}: {value}\r\n" for name, value in headers) + "\r\n"
                upstream.sendall(request.encode("iso-8859-1"))
                response = bytearray()
                while b"\r\n\r\n" not in response:
                    chunk = upstream.recv(4096)
                    if not chunk or len(response) + len(chunk) > 65536:
                        raise OSError("Invalid upstream handshake")
                    response.extend(chunk)
                if response.split(b"\r\n", 1)[0].split()[1:2] != [b"101"]:
                    self.send_body(502, b"Upgrade failed\n", False)
                    return
            except OSError:
                self.send_body(502, b"Upstream unavailable\n", False)
                return
            try:
                self.connection.sendall(response)
                relay(self.connection, upstream)
            except OSError:
                pass

    def send_body(self, status, body, head_only):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if status == 200:
            self.send_header("Profile-Update-Interval", "1")
        self.end_headers()
        self.close_connection = True
        if not head_only:
            self.wfile.write(body)

    def log_message(self, *_args):
        # Subscription paths contain credentials; do not log them.
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(10)


def relay(client, upstream):
    """Bounded, nonblocking full duplex, including backpressure and half-close."""
    peers = {client: upstream, upstream: client}
    pending = {client: bytearray(), upstream: bytearray()}
    reading = {client: True, upstream: True}
    closed_write = set()
    last_activity = time.monotonic()
    for stream in peers:
        stream.setblocking(False)
    with selectors.DefaultSelector() as selector:
        while True:
            for stream, peer in peers.items():
                if not reading[peer] and not pending[stream] and stream not in closed_write:
                    try:
                        stream.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    closed_write.add(stream)
                events = 0
                if reading[stream] and len(pending[peer]) < 262144:
                    events |= selectors.EVENT_READ
                if pending[stream]:
                    events |= selectors.EVENT_WRITE
                if stream in selector.get_map():
                    selector.unregister(stream)
                if events:
                    selector.register(stream, events)
            if not selector.get_map() or time.monotonic() - last_activity > 600:
                return
            for key, events in selector.select(timeout=10):
                stream, peer = key.fileobj, peers[key.fileobj]
                try:
                    if events & selectors.EVENT_READ:
                        data = stream.recv(65536)
                        if data:
                            pending[peer].extend(data)
                            last_activity = time.monotonic()
                        else:
                            reading[stream] = False
                    if events & selectors.EVENT_WRITE:
                        sent = stream.send(pending[stream])
                        del pending[stream][:sent]
                        if sent:
                            last_activity = time.monotonic()
                except BlockingIOError:
                    continue


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--export", metavar="DIRECTORY")
    parser.add_argument("--domain", default="")
    args = parser.parse_args()
    cfg = load_config(args.config)
    if args.export:
        directory = Path(args.export)
        domain = current_domain(cfg, args.domain)
        entries = nodes(cfg, domain)
        for name, link in entries.items():
            (directory / f"{name}-node.txt").write_text(link + "\n", encoding="utf-8")
        (directory / "all-nodes.txt").write_text("\n".join(entries.values()) + "\n", encoding="utf-8")
        (directory / "subscription.txt").write_bytes(payload(cfg, domain))
        (directory / "subscription-url.txt").write_text(subscription_url(cfg, domain) + "\n", encoding="utf-8")
        (directory / "subscription-direct-url.txt").write_text(subscription_url(cfg, direct=True) + "\n", encoding="utf-8")
        (directory / "current-tunnel-domain.txt").write_text(domain + "\n", encoding="utf-8")
        print(subscription_url(cfg, domain), flush=True)
        return
    server = ThreadingHTTPServer(("0.0.0.0", int(cfg["subscription_port"])), SubscriptionHandler)
    server.config_path = args.config
    print(f'Subscription listener ready on TCP {cfg["subscription_port"]}', flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
SUBSCRIPTION_PY
  chmod 0755 "$BIN_DIR/subscription.py"
}

render_xray_config() {
  jq --argjson rp "$REALITY_PORT" --argjson wp "$WS_PORT" --arg sni "$REALITY_SNI" '
    . as $ids |
    {log:{access:"none",loglevel:"warning"},inbounds:[
      {tag:"reality-in",listen:"0.0.0.0",port:$rp,protocol:"vless",
       settings:{decryption:"none",clients:[{id:$ids.account.direct,email:"direct-shared",flow:"xtls-rprx-vision"}]},
       streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,target:($sni+":443"),xver:0,
         serverNames:[$sni],privateKey:$ids.private_key,shortIds:[$ids.short_id]}}},
      {tag:"cloudflare-ws-in",listen:"127.0.0.1",port:$wp,protocol:"vless",
       settings:{decryption:"none",clients:[{id:$ids.account.cloudflare,email:"cf-shared"}]},
       streamSettings:{network:"ws",security:"none",wsSettings:{path:$ids.ws_path}}}
    ],outbounds:[{tag:"direct",protocol:"freedom",settings:{targetStrategy:"UseIPv4"}},{tag:"block",protocol:"blackhole"}],
    routing:{rules:[{type:"field",ip:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4","::/128","::1/128","fc00::/7","fe80::/10","ff00::/8"],outboundTag:"block"}]}}
  ' "$ETC_DIR/identities.json" > "$ETC_DIR/xray.json"
  append_saved_socks5
  chown root:"$SERVICE_USER" "$ETC_DIR/xray.json"
  chmod 0640 "$ETC_DIR/xray.json"
}

resolve_service_identity() {
  # CentOS 7 setpriv accepts only numeric IDs for --reuid/--regid.
  SERVICE_UID=$(id -u "$SERVICE_USER") || die 'Cannot resolve service user UID.'
  SERVICE_GID=$(id -g "$SERVICE_USER") || die 'Cannot resolve service user GID.'
  [[ $SERVICE_UID =~ ^[1-9][0-9]*$ && $SERVICE_GID =~ ^[1-9][0-9]*$ ]] \
    || die 'Expected non-root numeric service UID/GID.'
}

render_units() {
  local unit binary arguments
  if [[ $INIT_SYSTEM == openrc ]]; then render_openrc_units; return; fi
  resolve_service_identity
  cat > "$UNIT_DIR/$VPN_UNIT" <<UNIT
[Unit]
Description=Managed personal VPN REALITY and WebSocket
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=GOMEMLIMIT=64MiB
Environment=GOGC=75
Environment=GOMAXPROCS=2
ExecStart=$(command -v setpriv) --reuid=$SERVICE_UID --regid=$SERVICE_GID --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/xray run -config $ETC_DIR/xray.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
UMask=0077
LimitNOFILE=32768
[Install]
WantedBy=multi-user.target
UNIT
  cat > "$UNIT_DIR/$CF_UNIT" <<UNIT
[Unit]
Description=Managed personal VPN temporary Cloudflare Tunnel
Wants=network-online.target
After=network-online.target $VPN_UNIT $SUB_UNIT
Wants=$SUB_UNIT
[Service]
Type=simple
Environment=GOMEMLIMIT=64MiB
Environment=GOGC=75
Environment=GOMAXPROCS=2
ExecStartPre=$(command -v install) -d -m 0750 -o root -g $SERVICE_USER $RUN_DIR
ExecStartPre=$(command -v install) -m 0640 -o root -g $SERVICE_USER /dev/null $RUN_DIR/cloudflare.log
# Open the log only after ExecStartPre creates its directory (also after reboot).
StandardOutput=journal
StandardError=journal
ExecStart=/bin/sh -c 'exec $(command -v setpriv) --reuid=$SERVICE_UID --regid=$SERVICE_GID --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/cloudflared tunnel --url http://127.0.0.1:$SUB_PORT --no-autoupdate --protocol $TUNNEL_PROTOCOL --edge-ip-version 4 --metrics 127.0.0.1:$METRICS_PORT --loglevel info >>$RUN_DIR/cloudflare.log 2>&1'
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
UMask=0077
LimitNOFILE=16384
UNIT
  printf '\n[Install]\nWantedBy=multi-user.target\n' >> "$UNIT_DIR/$CF_UNIT"
  for unit in "$HY2_UNIT" "$SUB_UNIT"; do
    if [[ $unit == "$HY2_UNIT" ]]; then
      binary="$BIN_DIR/hysteria"
      arguments="server --config $ETC_DIR/hy2.json --disable-update-check"
    else
      binary=$(command -v python3)
      arguments="$BIN_DIR/subscription.py $ETC_DIR/subscription.json"
    fi
    cat > "$UNIT_DIR/$unit" <<UNIT
[Unit]
Description=Managed personal VPN ${unit%.service}
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=GOMEMLIMIT=64MiB
Environment=GOGC=75
Environment=GOMAXPROCS=2
ExecStart=$(command -v setpriv) --reuid=$SERVICE_UID --regid=$SERVICE_GID --clear-groups --bounding-set=-all --no-new-privs $binary $arguments
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
UMask=0077
LimitNOFILE=16384
[Install]
WantedBy=multi-user.target
UNIT
  done
  chmod 0644 "$UNIT_DIR/$VPN_UNIT" "$UNIT_DIR/$CF_UNIT" "$UNIT_DIR/$HY2_UNIT" "$UNIT_DIR/$SUB_UNIT"
}

render_openrc_units() {
  local unit binary arguments logfile service_path
  resolve_service_identity
  for unit in "$VPN_UNIT" "$CF_UNIT" "$HY2_UNIT" "$SUB_UNIT"; do
    if [[ $unit == "$VPN_UNIT" ]]; then
      binary="$BIN_DIR/xray"
      arguments="run -config $ETC_DIR/xray.json"
      logfile=xray.log
    elif [[ $unit == "$CF_UNIT" ]]; then
      binary="$BIN_DIR/cloudflared"
      arguments="tunnel --url http://127.0.0.1:$SUB_PORT --no-autoupdate --protocol $TUNNEL_PROTOCOL --edge-ip-version 4 --metrics 127.0.0.1:$METRICS_PORT --loglevel info"
      logfile=cloudflare.log
    elif [[ $unit == "$HY2_UNIT" ]]; then
      binary="$BIN_DIR/hysteria"
      arguments="server --config $ETC_DIR/hy2.json --disable-update-check"
      logfile=hy2.log
    else
      binary=$(command -v python3)
      arguments="$BIN_DIR/subscription.py $ETC_DIR/subscription.json"
      logfile=subscription.log
    fi
    service_path=$(service_file "$unit")
    cat > "$service_path" <<UNIT
#!/sbin/openrc-run
description="Managed personal VPN ${unit%.service}"
supervisor="supervise-daemon"
command="$(command -v setpriv)"
command_args="--reuid=$SERVICE_UID --regid=$SERVICE_GID --clear-groups --bounding-set=-all --no-new-privs $binary $arguments"
pidfile="$RUN_DIR/${unit%.service}.pid"
respawn_delay=5
respawn_max=0
# OpenRC 0.55 requires a positive period even when max=0 means unlimited.
respawn_period=60
output_log="$RUN_DIR/$logfile"
error_log="$RUN_DIR/$logfile"
export GOMEMLIMIT=64MiB GOGC=75 GOMAXPROCS=2
depend() {
  need net
UNIT
    if [[ $unit == "$CF_UNIT" ]]; then printf '  need %s %s\n' "${VPN_UNIT%.service}" "${SUB_UNIT%.service}" >> "$service_path"; fi
    cat >> "$service_path" <<UNIT
}
start_pre() {
  checkpath --directory --mode 0750 --owner root:$SERVICE_USER "$RUN_DIR" || return 1
  : > "$RUN_DIR/$logfile"
  chown root:$SERVICE_USER "$RUN_DIR/$logfile"
  chmod 0640 "$RUN_DIR/$logfile"
  ulimit -n 16384 2>/dev/null || true
}
UNIT
    chmod 0755 "$service_path"
  done
}

current_domain() {
  local pid
  if [[ $INIT_SYSTEM == openrc || -r "$RUN_DIR/cloudflare.log" ]]; then
    svc is-active "$CF_UNIT" && [[ -r "$RUN_DIR/cloudflare.log" ]] || return 1
    grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$RUN_DIR/cloudflare.log" | tail -n 1 | sed 's#https://##'
    return
  fi
  pid=$(systemctl show "$CF_UNIT" --property MainPID --value)
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  journalctl -b -u "$CF_UNIT" "_PID=$pid" -o cat --no-pager 2>/dev/null \
    | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -n 1 | sed 's#https://##'
}

wait_tunnel() {
  local deadline domain
  say 'Waiting up to 90 seconds for the Quick Tunnel.'
  deadline=$((SECONDS + 90))
  while ((SECONDS < deadline)); do
    domain=$(current_domain || true)
    if [[ -n $domain ]] && curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$METRICS_PORT/ready" >/dev/null 2>&1; then
      CURRENT_DOMAIN=$domain
      return 0
    fi
    sleep 1
  done
  tunnel_logs
  return 1
}

urlencode() { jq -rn --arg value "$1" '$value | @uri'; }
export_nodes() {
  local domain=${1:-} export_tmp file url
  [[ -f "$BIN_DIR/subscription.py" && -f "$ETC_DIR/subscription.json" ]] || die '请先选择安装 / 更新，升级为 Hy2 + 订阅版本。'
  [[ -z $domain ]] || valid_host "$domain" || die 'Invalid current tunnel hostname.'
  [[ ! -L $OUTPUT_DIR ]] || die 'Export directory must not be a symlink.'
  if [[ -d $OUTPUT_DIR && ! -f "$OUTPUT_DIR/.personal-vpn-stack-exports" ]]; then
    [[ -z $(ls -A -- "$OUTPUT_DIR") ]] || die 'Choose an empty export directory.'
  fi
  install -d -m 0700 "$OUTPUT_DIR"
  printf '%s\n' "$MARKER" > "$OUTPUT_DIR/.personal-vpn-stack-exports"
  export_tmp=$(mktemp -d "$OUTPUT_DIR/.export.XXXXXXXX")
  url=$(python3 "$BIN_DIR/subscription.py" "$ETC_DIR/subscription.json" --export "$export_tmp" --domain "$domain")
  if command -v qrencode >/dev/null; then
    for file in "$export_tmp"/CF-node.txt "$export_tmp"/REALITY-node.txt "$export_tmp"/Hy2-node.txt "$export_tmp"/subscription-url.txt; do
      [[ ! -f $file ]] || tr -d '\r\n' < "$file" | qrencode -t PNG -s 6 -o "${file%.txt}.png"
    done
  fi
  if [[ ! -f "$export_tmp/Hy2-node.txt" ]]; then
    rm -f -- "$OUTPUT_DIR/Hy2-node.txt" "$OUTPUT_DIR/Hy2-node.png"
  fi
  for file in "$export_tmp"/*; do mv -f -- "$file" "$OUTPUT_DIR/"; done
  rmdir "$export_tmp"
  say "Client files: $OUTPUT_DIR"
  printf '\n共用订阅链接（导入客户端的“订阅”功能）：\n%s\n' "$url"
  say '默认使用 Cloudflare HTTPS 订阅，无需开放公网订阅端口；直连备用地址见 subscription-direct-url.txt。请勿公开订阅地址。'
  say '临时隧道重建后 HTTPS 订阅域名可能变化，请重新查看并导入；直连备用 URL 保持不变。'
}

install_stack() {
  local cf_restart=1
  HY2_ENABLED=1
  check_platform
  [[ ! -L $ETC_DIR && ! -L $BIN_DIR ]] || die 'Managed directories must not be symlinks.'
  if [[ -d $ETC_DIR ]]; then
    [[ -r "$ETC_DIR/managed-by" && $(cat "$ETC_DIR/managed-by") == "$MARKER" ]] || die "Refusing to overwrite an unmanaged directory: $ETC_DIR"
  else
    [[ ! -e $(service_file "$VPN_UNIT") && ! -e $(service_file "$CF_UNIT") && ! -e $(service_file "$HY2_UNIT") && ! -e $(service_file "$SUB_UNIT") && ! -e $BIN_DIR ]] || die 'Unmanaged stack files already exist.'
  fi
  install_dependencies
  load_settings
  if ((INTERACTIVE_INSTALL)); then interactive_settings; fi
  detect_node_country
  validate_settings
  check_ports
  make_workdir
  stage_binaries
  if ((HY2_ENABLED)); then
    if attempt_hy2 download stage_hy2_binary; then
      HY2_VERSION=$(cat "$WORK_DIR/hy2-version")
    else
      HY2_ENABLED=0
    fi
  fi
  backup_managed_files
  ensure_user
  install -d -m 0750 -o root -g "$SERVICE_USER" "$ETC_DIR"
  install -d -m 0755 "$BIN_DIR"
  install -d -m 0700 "$DATA_DIR"
  printf '%s\n' "$MARKER" > "$ETC_DIR/managed-by"
  if ((CF_WAS_ACTIVE)) && cmp -s "$WORK_DIR/cloudflared" "$BIN_DIR/cloudflared"; then cf_restart=0; fi
  install -m 0755 "$WORK_DIR/xray" "$BIN_DIR/xray"
  install -m 0755 "$WORK_DIR/cloudflared" "$BIN_DIR/cloudflared"
  ensure_identities
  if ((HY2_ENABLED)); then
    if ! attempt_hy2 prepare prepare_hy2; then HY2_ENABLED=0; fi
  fi
  write_settings
  render_xray_config
  write_subscription_config
  render_subscription_server
  apply_selinux_contexts
  "$BIN_DIR/xray" run -test -config "$ETC_DIR/xray.json"
  render_units
  if ! cmp -s "$(service_file "$CF_UNIT")" "$WORK_DIR/backup$(service_file "$CF_UNIT")"; then cf_restart=1; fi
  printf '%s\n' "$MARKER" > "$ETC_DIR/managed-by"
  svc reload
  if ((!HY2_ENABLED)); then skip_hy2; fi
  restart_service "$VPN_UNIT"
  restart_service "$SUB_UNIT"
  if ((cf_restart)); then restart_service "$CF_UNIT"; fi
  if ! wait_tunnel; then collect_failure_diagnostics; rollback; INSTALL_TRANSACTION=0; die 'Tunnel did not become ready. Check outbound DNS and TCP/UDP 7844 access.'; fi
  if ((HY2_ENABLED)); then
    if ! attempt_hy2 start start_hy2; then
      skip_hy2
      write_settings
      write_subscription_config
    fi
  fi
  if ! wait_subscription; then collect_failure_diagnostics; die 'Subscription failed to become ready.'; fi
  svc enable "$VPN_UNIT" "$CF_UNIT" "$SUB_UNIT"
  INSTALL_TRANSACTION=0
  SELINUX_RULE_ADDED=0
  export_nodes "$CURRENT_DOMAIN"
  if [[ -f "$ETC_DIR/socks5.json" ]]; then show_socks5; fi
  if [[ -f "$ETC_DIR/mtproto.json" ]]; then show_mtproto; fi
  say 'Installation is ready. This confirms service/tunnel readiness, not an end-to-end speed test.'
  if ((HY2_ENABLED)); then
    say "Hy2 已启用，需要 UDP $HY2_PUBLIC_PORT → $HY2_PORT。"
  else
    say 'Hy2 已跳过，订阅包含 CF 和 REALITY 两个节点；下次安装 / 更新会重新尝试 Hy2。'
  fi
  say '已成功安装的服务均设置开机自启；临时隧道域名变化后，请重新查看并替换 HTTPS 订阅地址。'
  say "Cloudflare 节点和 HTTPS 订阅无需公网端口映射。REALITY 需要 TCP $PUBLIC_PORT → $REALITY_PORT；直连订阅备用才需要 TCP $SUB_PUBLIC_PORT → $SUB_PORT。"
}

wait_hy2() {
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if svc is-active "$HY2_UNIT" && ss -H -lun "sport = :$HY2_PORT" | grep -q .; then return 0; fi
    sleep 1
  done
  if [[ $INIT_SYSTEM == openrc ]]; then
    [[ ! -r "$RUN_DIR/hy2.log" ]] || tail -n 30 "$RUN_DIR/hy2.log" >&2
  else
    journalctl -u "$HY2_UNIT" -n 30 --no-pager >&2 || true
  fi
  return 1
}

wait_subscription() {
  local token deadline
  token=$(jq -er '.subscription_token' "$ETC_DIR/identities.json")
  deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if svc is-active "$VPN_UNIT" && svc is-active "$SUB_UNIT"; then
      if curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$SUB_PORT/$token" -o "$WORK_DIR/subscription-health.txt" && \
         python3 -c 'import base64,sys; x=base64.b64decode(open(sys.argv[1],"rb").read(),validate=True).decode().splitlines(); enabled=sys.argv[2]=="1"; assert sum(n.startswith("vless://") for n in x)==2; assert sum(n.startswith("hysteria2://") for n in x)==int(enabled)' "$WORK_DIR/subscription-health.txt" "$HY2_ENABLED"; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

uninstall_stack() {
  local answer file title
  need_installation
  for file in "$ETC_DIR" "$BIN_DIR" "$DATA_DIR" "$DATA_DIR/clients"; do
    [[ ! -L $file ]] || die "拒绝卸载符号链接目录：$file"
  done
  printf '\n将卸载本脚本的 Cloudflare、REALITY、Hy2、SOCKS5、MTProto 和订阅服务，删除程序、账号配置及默认目录中的节点文件。\nSSH、防火墙及手工部署的旧服务不受影响。\n'
  read -r -p '确认卸载？输入 y 继续 [N]：' answer || return 0
  [[ $answer == y || $answer == Y ]] || { say '已取消卸载。'; return 0; }
  if [[ -f "$ETC_DIR/mtproto-selinux-fcontext" ]]; then
    [[ $(cat "$ETC_DIR/mtproto-selinux-fcontext") == "$BIN_DIR/mtg" ]] || die "Unexpected MTProto SELinux rule."
    semanage fcontext -d "$BIN_DIR/mtg"
  fi
  if [[ -f $(service_file "$MT_UNIT") ]]; then
    svc stop "$MT_UNIT"
    svc disable "$MT_UNIT"
    rm -f -- "$(service_file "$MT_UNIT")"
  fi
  remove_selinux_contexts
  svc stop "$SUB_UNIT" "$HY2_UNIT" "$CF_UNIT" "$VPN_UNIT"
  svc disable "$SUB_UNIT" "$HY2_UNIT" "$CF_UNIT" "$VPN_UNIT" >/dev/null 2>&1 || true
  rm -f -- "$(service_file "$CF_UNIT")" "$(service_file "$VPN_UNIT")" "$(service_file "$HY2_UNIT")" "$(service_file "$SUB_UNIT")"
  svc reload
  svc reset-failed "$CF_UNIT" "$VPN_UNIT" "$HY2_UNIT" "$SUB_UNIT" >/dev/null 2>&1 || true
  rm -rf -- "$BIN_DIR" "$ETC_DIR"
  if [[ -f "$DATA_DIR/clients/.personal-vpn-stack-exports" ]] &&
     [[ $(cat "$DATA_DIR/clients/.personal-vpn-stack-exports") == "$MARKER" ]]; then
    for title in node Windows iPhone Mac; do
      rm -f -- "$DATA_DIR/clients/CF-$title.txt" "$DATA_DIR/clients/CF-$title.png" \
        "$DATA_DIR/clients/REALITY-$title.txt" "$DATA_DIR/clients/REALITY-$title.png"
    done
    rm -f -- "$DATA_DIR/clients/Hy2-node.txt" "$DATA_DIR/clients/Hy2-node.png" \
      "$DATA_DIR/clients/subscription.txt" "$DATA_DIR/clients/subscription-direct-url.txt" "$DATA_DIR/clients/subscription-url.txt" "$DATA_DIR/clients/subscription-url.png"
    rm -f -- "$DATA_DIR/clients/all-nodes.txt" "$DATA_DIR/clients/current-tunnel-domain.txt" "$DATA_DIR/clients/.personal-vpn-stack-exports"
    rmdir -- "$DATA_DIR/clients" 2>/dev/null || true
  fi
  rmdir -- "$DATA_DIR" 2>/dev/null || true
  if id "$SERVICE_USER" >/dev/null 2>&1; then userdel "$SERVICE_USER"; fi
  if getent group "$SERVICE_USER" >/dev/null; then groupdel "$SERVICE_USER"; fi
  if [[ $INIT_SYSTEM == openrc && ! -L $RUN_DIR ]]; then
    rm -f -- "$RUN_DIR/cloudflare.log" "$RUN_DIR/xray.log" "$RUN_DIR/hy2.log" "$RUN_DIR/subscription.log" \
      "$RUN_DIR/${VPN_UNIT%.service}.pid" "$RUN_DIR/${CF_UNIT%.service}.pid" "$RUN_DIR/${HY2_UNIT%.service}.pid" "$RUN_DIR/${SUB_UNIT%.service}.pid" \
      "$RUN_DIR/mtproto.log" "$RUN_DIR/${MT_UNIT%.service}.pid"
    rmdir -- "$RUN_DIR" 2>/dev/null || true
  fi
  say '卸载完成。自行复制或自定义目录导出的节点文件可自行删除。'
}

validate_socks5_file() {
  jq -e '
    .username == "admin" and
    (.password | type == "string" and test("^[a-f0-9]{32}$")) and
    (.port | type == "number" and floor == . and . >= 1024 and . <= 65535) and
    (.public_port | type == "number" and floor == . and . >= 1024 and . <= 65535)
  ' "$1" >/dev/null || die 'Invalid SOCKS5 configuration; refusing to enable an unauthenticated proxy.'
}

validate_socks5_ports() {
  local port
  for port in "$1" "$2"; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port >= 1024 && port <= 65535)) || die 'SOCKS5 ports must be between 1024 and 65535.'
  done
  for port in "$REALITY_PORT" "$WS_PORT" "$METRICS_PORT" "$SUB_PORT"; do
    [[ $1 != "$port" ]] || die "SOCKS5 TCP port $1 conflicts with another stack listener."
  done
  [[ $2 != "$PUBLIC_PORT" && $2 != "$SUB_PUBLIC_PORT" ]] || die 'SOCKS5 public TCP port conflicts with REALITY or subscription.'
}

check_socks5_port() {
  local port=$1
  if ss -H -ltn "sport = :$port" | grep -q .; then
    if [[ ! -r "$ETC_DIR/socks5.json" || ! -r "$ETC_DIR/xray.json" ]] ||
       ! jq -e --argjson port "$port" 'any(.inbounds[]; .tag == "socks5-in" and .protocol == "socks" and .port == $port)' "$ETC_DIR/xray.json" >/dev/null ||
       ! svc is-active "$VPN_UNIT"; then
      die "TCP port $port is occupied by another service. Existing services were not changed."
    fi
  fi
}

merge_socks5_config() {
  validate_socks5_file "$2"
  jq --slurpfile socks "$2" '
    $socks[0] as $s |
    .inbounds = ([.inbounds[] | select(.tag != "socks5-in")] + [
      {tag:"socks5-in",listen:"0.0.0.0",port:$s.port,protocol:"socks",
       settings:{auth:"password",accounts:[{user:$s.username,pass:$s.password}],udp:false}}
    ])
  ' "$1" > "$3"
}

append_saved_socks5() {
  [[ -f "$ETC_DIR/socks5.json" ]] || return 0
  merge_socks5_config "$ETC_DIR/xray.json" "$ETC_DIR/socks5.json" "$WORK_DIR/xray-with-socks5.json"
  cat "$WORK_DIR/xray-with-socks5.json" > "$ETC_DIR/xray.json"
}

rollback_socks5() {
  ((SOCKS_TRANSACTION)) || return 0
  SOCKS_TRANSACTION=0
  say 'SOCKS5 配置失败，正在恢复原配置。'
  cp -a -- "$WORK_DIR/socks5-xray-backup.json" "$ETC_DIR/xray.json" || true
  if ((SOCKS_HAD_CONFIG)); then
    cp -a -- "$WORK_DIR/socks5-backup.json" "$ETC_DIR/socks5.json" || true
  else
    rm -f -- "$ETC_DIR/socks5.json"
  fi
  if ((SOCKS_WAS_ACTIVE)); then
    svc restart "$VPN_UNIT" || true
  else
    svc stop "$VPN_UNIT" || true
  fi
}

show_socks5() {
  [[ -r "$ETC_DIR/socks5.json" ]] || die '尚未启用 SOCKS5，请先选择安装 / 更新 SOCKS5。'
  validate_socks5_file "$ETC_DIR/socks5.json"
  jq -r --arg server "$SERVER_ADDR" '
    "\nTelegram → 设置 → 数据与存储 → 代理 → 添加代理 → SOCKS5",
    "服务器：\($server)", "端口：\(.public_port)",
    "用户名：\(.username)", "密码：\(.password)",
    "\nTelegram 一键添加链接（含密码，请勿公开）：",
    ("tg://socks?server=" + ($server|@uri) + "&port=" + (.public_port|tostring) +
     "&user=" + (.username|@uri) + "&pass=" + (.password|@uri)),
    "\n请放行 TCP \(.port)；NAT 服务器还需配置公网 TCP \(.public_port) → 内部 TCP \(.port)。",
    "这是 SOCKS5 直连，不经过 CF；本入口仅支持 TCP，不提供 UDP 转发。"
  ' "$ETC_DIR/socks5.json"
  say "账号保存在 $ETC_DIR/socks5.json（仅 root 可读）；再次运行保留原密码。"
}

wait_socks5() {
  python3 - "$ETC_DIR/socks5.json" <<'PY'
import json
import socket
import sys
import time

with open(sys.argv[1], encoding="utf-8") as source:
    cfg = json.load(source)

def receive(sock, count):
    result = b""
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise OSError("SOCKS5 closed the connection")
        result += part
    return result

user = cfg["username"].encode("utf-8")
password = cfg["password"].encode("utf-8")
for attempt in range(20):
    try:
        with socket.create_connection(("127.0.0.1", cfg["port"]), timeout=0.5) as sock:
            sock.sendall(b"\x05\x01\x02")
            if receive(sock, 2) != b"\x05\x02":
                raise OSError("SOCKS5 password authentication is not required")
            sock.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
            if receive(sock, 2) != b"\x01\x00":
                raise OSError("SOCKS5 authentication failed")
        sys.exit(0)
    except OSError:
        time.sleep(0.25)
sys.exit("SOCKS5 did not pass the local authentication check")
PY
}

install_socks5() {
  local old_port=53528 old_public_port candidate
  [[ -x "$BIN_DIR/xray" && -r "$ETC_DIR/xray.json" ]] || die '请先安装原节点服务，再新增 SOCKS5。'
  [[ ! -L "$ETC_DIR" && ! -L "$ETC_DIR/socks5.json" && ! -L "$ETC_DIR/xray.json" ]] || die 'SOCKS5 managed files must not be symlinks.'
  command -v openssl >/dev/null && command -v python3 >/dev/null && command -v ss >/dev/null || die 'Missing openssl, python3 or ss; run install/update first.'
  if [[ -f "$ETC_DIR/socks5.json" ]]; then
    validate_socks5_file "$ETC_DIR/socks5.json"
    old_port=$(jq -r '.port' "$ETC_DIR/socks5.json")
    old_public_port=$(jq -r '.public_port' "$ETC_DIR/socks5.json")
  fi
  SOCKS_PORT=${SOCKS_PORT:-$old_port}
  SOCKS_PUBLIC_PORT=${SOCKS_PUBLIC_PORT:-${old_public_port:-$SOCKS_PORT}}
  validate_socks5_ports "$SOCKS_PORT" "$SOCKS_PUBLIC_PORT"
  if jq -e --argjson port "$SOCKS_PORT" 'any(.inbounds[]; .tag != "socks5-in" and .port == $port)' "$ETC_DIR/xray.json" >/dev/null; then
    die 'SOCKS5 port conflicts with an existing Xray listener.'
  fi
  if [[ -f "$ETC_DIR/mtproto.json" ]]; then
    [[ $SOCKS_PORT != "$(jq -r .port "$ETC_DIR/mtproto.json")" && $SOCKS_PUBLIC_PORT != "$(jq -r .public_port "$ETC_DIR/mtproto.json")" ]] || die "SOCKS5 port conflicts with MTProto."
  fi
  check_socks5_port "$SOCKS_PORT"
  make_workdir
  candidate="$WORK_DIR/socks5-candidate.json"
  if [[ -f "$ETC_DIR/socks5.json" ]]; then
    jq --argjson port "$SOCKS_PORT" --argjson public "$SOCKS_PUBLIC_PORT" \
      '.port=$port | .public_port=$public' "$ETC_DIR/socks5.json" > "$candidate"
  else
    openssl rand -hex 16 > "$WORK_DIR/socks5-password"
    jq -n --argjson port "$SOCKS_PORT" --argjson public "$SOCKS_PUBLIC_PORT" \
      --rawfile password "$WORK_DIR/socks5-password" \
      '{username:"admin",password:($password|rtrimstr("\n")),port:$port,public_port:$public}' > "$candidate"
  fi
  merge_socks5_config "$ETC_DIR/xray.json" "$candidate" "$WORK_DIR/socks5-xray-candidate.json"
  "$BIN_DIR/xray" run -test -config "$WORK_DIR/socks5-xray-candidate.json"
  cp -a -- "$ETC_DIR/xray.json" "$WORK_DIR/socks5-xray-backup.json"
  if [[ -f "$ETC_DIR/socks5.json" ]]; then
    cp -a -- "$ETC_DIR/socks5.json" "$WORK_DIR/socks5-backup.json"
    SOCKS_HAD_CONFIG=1
  fi
  if svc is-active "$VPN_UNIT"; then SOCKS_WAS_ACTIVE=1; fi
  SOCKS_TRANSACTION=1
  trap 'die "SOCKS5 configuration interrupted."' INT TERM
  install -m 0600 "$candidate" "$ETC_DIR/socks5.json"
  install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/socks5-xray-candidate.json" "$ETC_DIR/xray.json"
  restart_service "$VPN_UNIT"
  wait_socks5
  svc enable "$VPN_UNIT"
  SOCKS_TRANSACTION=0
  trap - INT TERM
  say 'SOCKS5 已启用，本机账号认证检查通过；手机直连仍需放行端口并实际测试。'
  show_socks5
}

validate_mtproto_file() {
  jq -e '
    (.secret | type == "string" and test("^ee[a-f0-9]{32}([a-f0-9]{2})+$")) and
    (.port | type == "number" and floor == . and . >= 1024 and . <= 65535) and
    (.public_port | type == "number" and floor == . and . >= 1024 and . <= 65535)
  ' "$1" >/dev/null || die 'Invalid MTProto configuration.'
}

validate_mtproto_ports() {
  local port
  for port in "$1" "$2"; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port >= 1024 && port <= 65535)) || die 'MTProto ports must be between 1024 and 65535.'
  done
  for port in "$REALITY_PORT" "$WS_PORT" "$METRICS_PORT" "$SUB_PORT"; do
    [[ $1 != "$port" ]] || die "MTProto TCP port $1 conflicts with another stack listener."
  done
  [[ $2 != "$PUBLIC_PORT" && $2 != "$SUB_PUBLIC_PORT" ]] || die 'MTProto public TCP port conflicts with REALITY or subscription.'
}

stage_mtg() {
  local arch
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die 'MTProto supports amd64 and arm64.' ;;
  esac
  say 'Downloading official mtg v2.2.8 and verifying SHA-256.'
  download_asset 9seconds/mtg v2.2.8 "mtg-2.2.8-linux-$arch.tar.gz" "$WORK_DIR/mtg.tar.gz"
  mkdir "$WORK_DIR/mtg-stage"
  tar -xzf "$WORK_DIR/mtg.tar.gz" -C "$WORK_DIR/mtg-stage" --strip-components=1 "mtg-2.2.8-linux-$arch/mtg"
  chmod 0755 "$WORK_DIR/mtg-stage/mtg"
  "$WORK_DIR/mtg-stage/mtg" --version
}

render_mtproto_config() {
  validate_mtproto_file "$1"
  # Values are validated before interpolation; no secret is passed in argv.
  {
    printf 'secret = "%s"\n' "$(jq -r .secret "$1")"
    printf 'bind-to = "0.0.0.0:%s"\n' "$(jq -r .port "$1")"
    printf '%s\n' 'prefer-ip = "only-ipv4"' 'concurrency = 512'
    printf '\n[network]\ndns = ""\n'
    # Provider NAT can forward clients from private IPs. Do not download a
    # public blocklist which silently rejects those clients. Secret is required.
    printf '\n[defense.blocklist]\nenabled = false\n'
    printf '\n[defense.anti-replay]\nenabled = true\n'
  } > "$2"
}

render_mtproto_unit() {
  resolve_service_identity
  if [[ $INIT_SYSTEM == openrc ]]; then
    cat > "$(service_file "$MT_UNIT")" <<UNIT
#!/sbin/openrc-run
description="Managed Telegram MTProto proxy"
supervisor="supervise-daemon"
command="$(command -v setpriv)"
command_args="--reuid=$SERVICE_UID --regid=$SERVICE_GID --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/mtg run $ETC_DIR/mtproto.toml"
pidfile="$RUN_DIR/${MT_UNIT%.service}.pid"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="$RUN_DIR/mtproto.log"
error_log="$RUN_DIR/mtproto.log"
export GOMEMLIMIT=64MiB GOGC=75 GOMAXPROCS=2
depend() {
  need net
}
start_pre() {
  checkpath --directory --mode 0750 --owner root:$SERVICE_USER "$RUN_DIR" || return 1
  : > "$RUN_DIR/mtproto.log"
  chown root:$SERVICE_USER "$RUN_DIR/mtproto.log"
  chmod 0640 "$RUN_DIR/mtproto.log"
  ulimit -n 16384 2>/dev/null || true
}
UNIT
    chmod 0755 "$(service_file "$MT_UNIT")"
  else
    cat > "$(service_file "$MT_UNIT")" <<UNIT
[Unit]
Description=Managed Telegram MTProto proxy
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=GOMEMLIMIT=64MiB
Environment=GOGC=75
Environment=GOMAXPROCS=2
ExecStart=$(command -v setpriv) --reuid=$SERVICE_UID --regid=$SERVICE_GID --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/mtg run $ETC_DIR/mtproto.toml
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
UMask=0077
LimitNOFILE=16384
[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$(service_file "$MT_UNIT")"
  fi
}

mtproto_enabled() {
  if [[ $INIT_SYSTEM == openrc ]]; then
    [[ -L /etc/runlevels/default/${MT_UNIT%.service} ]]
  else
    systemctl is-enabled --quiet "$MT_UNIT"
  fi
}

mtproto_selinux() {
  selinux_active || return 0
  command -v semanage >/dev/null && command -v restorecon >/dev/null || die 'SELinux requires semanage and restorecon.'
  if [[ -f "$ETC_DIR/mtproto-selinux-fcontext" ]]; then
    [[ $(cat "$ETC_DIR/mtproto-selinux-fcontext") == "$BIN_DIR/mtg" ]] || die 'Unexpected MTProto SELinux rule.'
    semanage fcontext -m -t bin_t "$BIN_DIR/mtg"
  else
    semanage fcontext -a -t bin_t "$BIN_DIR/mtg"
    MT_SELINUX_ADDED=1
    printf '%s\n' "$BIN_DIR/mtg" > "$ETC_DIR/mtproto-selinux-fcontext"
  fi
  restorecon -F "$BIN_DIR/mtg"
}

rollback_mtproto() {
  ((MT_TRANSACTION)) || return 0
  MT_TRANSACTION=0
  say 'MTProto 安装失败，正在恢复原配置。'
  svc stop "$MT_UNIT" || true
  if ((!MT_WAS_ENABLED)); then svc disable "$MT_UNIT" || true; fi
  if ((MT_SELINUX_ADDED)); then semanage fcontext -d "$BIN_DIR/mtg" || true; fi
  local file
  for file in "${MT_FILES[@]}"; do
    if [[ -e "$WORK_DIR/mt-backup$file" ]]; then
      cp -a -- "$WORK_DIR/mt-backup$file" "$file" || true
    else
      rm -f -- "$file" || true
    fi
  done
  svc reload || true
  if ((MT_XRAY_CHANGED && MT_VPN_WAS_ACTIVE)); then svc restart "$VPN_UNIT" || true; fi
  if ((MT_WAS_ENABLED)); then svc enable "$MT_UNIT" || true; fi
  if ((MT_WAS_ACTIVE)); then svc start "$MT_UNIT" || true; fi
}

wait_mtproto() {
  local port=$1 attempt
  for attempt in {1..20}; do
    if svc is-active "$MT_UNIT" && python3 - "$port" <<'PY'
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
    pass
PY
    then
      sleep 1
      svc is-active "$MT_UNIT" && return 0
    fi
    sleep 0.5
  done
  if [[ $INIT_SYSTEM == openrc ]]; then
    tail -n 30 "$RUN_DIR/mtproto.log" >&2 || true
  else
    journalctl -u "$MT_UNIT" -n 30 --no-pager >&2 || true
  fi
  return 1
}

show_mtproto() {
  [[ -r "$ETC_DIR/mtproto.json" ]] || die '请先运行 mtproto 安装 MTProto。'
  validate_mtproto_file "$ETC_DIR/mtproto.json"
  jq -r --arg server "$SERVER_ADDR" '
    "\nTelegram → 设置 → 数据与存储 → 代理 → 添加代理 → MTProto",
    "服务器：\($server)", "端口：\(.public_port)", "Secret：\(.secret)",
    "\nTelegram 一键添加链接（含密钥，请勿公开）：",
    ("tg://proxy?server=" + ($server|@uri) + "&port=" + (.public_port|tostring) + "&secret=" + .secret),
    "\n请放行 TCP \(.port)；NAT 服务器需要公网 TCP \(.public_port) → 内部 TCP \(.port)。",
    "此入口为 MTProto 直连，不经过 CF；只代理 Telegram，无需用户名和密码。"
  ' "$ETC_DIR/mtproto.json"
  say "密钥保存在 $ETC_DIR/mtproto.json（仅 root 可读）；更新时保留。"
}

install_mtproto() {
  local file old_port=53528 old_public= candidate port_owned=0
  [[ -x "$BIN_DIR/xray" && -r "$ETC_DIR/xray.json" ]] || die '请先安装原节点服务，再新增 MTProto。'
  command -v python3 >/dev/null && command -v ss >/dev/null && command -v tar >/dev/null || die 'Missing python3, ss or tar; run install/update first.'
  MT_FILES=("$BIN_DIR/mtg" "$ETC_DIR/mtproto.json" "$ETC_DIR/mtproto.toml"
    "$ETC_DIR/xray.json" "$ETC_DIR/socks5.json" "$ETC_DIR/mtproto-selinux-fcontext" "$(service_file "$MT_UNIT")")
  [[ ! -L $ETC_DIR && ! -L $BIN_DIR ]] || die 'Managed directories must not be symlinks.'
  for file in "${MT_FILES[@]}"; do [[ ! -L $file ]] || die "Managed file must not be a symlink: $file"; done
  if [[ -f "$ETC_DIR/mtproto.json" ]]; then
    validate_mtproto_file "$ETC_DIR/mtproto.json"
    old_port=$(jq -r .port "$ETC_DIR/mtproto.json")
    old_public=$(jq -r .public_port "$ETC_DIR/mtproto.json")
  elif [[ -e "$BIN_DIR/mtg" || -e $(service_file "$MT_UNIT") || -e "$ETC_DIR/mtproto.toml" ]]; then
    die 'MTProto files exist without managed credentials; refusing to overwrite.'
  fi
  MT_PORT=${MT_PORT:-$old_port}
  MT_PUBLIC_PORT=${MT_PUBLIC_PORT:-${old_public:-$MT_PORT}}
  validate_mtproto_ports "$MT_PORT" "$MT_PUBLIC_PORT"
  if jq -e --argjson port "$MT_PORT" 'any(.inbounds[]; .tag != "socks5-in" and .port == $port)' "$ETC_DIR/xray.json" >/dev/null; then
    die 'MTProto port conflicts with an existing Xray listener.'
  fi
  if jq -e 'any(.inbounds[]; .tag == "socks5-in" and .protocol != "socks")' "$ETC_DIR/xray.json" >/dev/null; then
    die 'Unexpected socks5-in protocol; refusing migration.'
  fi
  if [[ -f "$ETC_DIR/mtproto.json" && $MT_PORT == "$old_port" ]] && svc is-active "$MT_UNIT"; then port_owned=1; fi
  if jq -e --argjson port "$MT_PORT" 'any(.inbounds[]; .tag == "socks5-in" and .protocol == "socks" and .port == $port)' "$ETC_DIR/xray.json" >/dev/null && svc is-active "$VPN_UNIT"; then port_owned=1; fi
  if ss -H -ltn "sport = :$MT_PORT" | grep -q . && (( !port_owned )); then
    die "TCP $MT_PORT is occupied by another service."
  fi
  make_workdir
  stage_mtg
  candidate="$WORK_DIR/mtproto-candidate.json"
  if [[ -f "$ETC_DIR/mtproto.json" ]]; then
    jq --argjson port "$MT_PORT" --argjson public "$MT_PUBLIC_PORT" '.port=$port | .public_port=$public' "$ETC_DIR/mtproto.json" > "$candidate"
  else
    "$WORK_DIR/mtg-stage/mtg" generate-secret --hex www.cloudflare.com > "$WORK_DIR/mt-secret"
    jq -n --rawfile secret "$WORK_DIR/mt-secret" --argjson port "$MT_PORT" --argjson public "$MT_PUBLIC_PORT" \
      '{secret:($secret|gsub("[\\r\\n]";"")),port:$port,public_port:$public}' > "$candidate"
  fi
  render_mtproto_config "$candidate" "$WORK_DIR/mtproto.toml"
  jq '.inbounds |= map(select(.tag != "socks5-in"))' "$ETC_DIR/xray.json" > "$WORK_DIR/mt-xray.json"
  "$BIN_DIR/xray" run -test -config "$WORK_DIR/mt-xray.json"
  mkdir "$WORK_DIR/mt-backup"
  for file in "${MT_FILES[@]}"; do [[ ! -e $file ]] || cp -a --parents "$file" "$WORK_DIR/mt-backup"; done
  if svc is-active "$MT_UNIT"; then MT_WAS_ACTIVE=1; fi
  if mtproto_enabled; then MT_WAS_ENABLED=1; fi
  if svc is-active "$VPN_UNIT"; then MT_VPN_WAS_ACTIVE=1; fi
  MT_TRANSACTION=1
  trap 'die "MTProto installation interrupted."' INT TERM
  if [[ -f $(service_file "$MT_UNIT") ]]; then svc stop "$MT_UNIT"; fi
  install -m 0755 "$WORK_DIR/mtg-stage/mtg" "$BIN_DIR/mtg"
  install -m 0600 "$candidate" "$ETC_DIR/mtproto.json"
  install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/mtproto.toml" "$ETC_DIR/mtproto.toml"
  mtproto_selinux
  render_mtproto_unit
  svc reload
  if jq -e 'any(.inbounds[]; .tag == "socks5-in")' "$ETC_DIR/xray.json" >/dev/null; then
    MT_XRAY_CHANGED=1
    install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/mt-xray.json" "$ETC_DIR/xray.json"
    if ((MT_VPN_WAS_ACTIVE)); then restart_service "$VPN_UNIT"; fi
  fi
  rm -f -- "$ETC_DIR/socks5.json"
  restart_service "$MT_UNIT"
  wait_mtproto "$MT_PORT"
  svc enable "$MT_UNIT"
  MT_TRANSACTION=0
  trap - INT TERM
  say 'MTProto 已启动并设置开机自启，本机监听检查通过；Telegram 外网连接请在手机上实测。'
  show_mtproto
}

configure_time_sync() {
  local unit=chronyd.service other
  say '配置 Chrony 自动校时，防止时钟偏差导致 MTProto 握手失败。'
  if ! command -v chronyd >/dev/null || ! command -v chronyc >/dev/null; then
    case $PACKAGE_MANAGER in
      apt) apt_install_packages chrony || die 'Chrony 安装失败，请检查上方的软件源错误。' ;;
      dnf|yum) prepare_legacy_centos_repos; rpm_install chrony ;;
      apk) apk add --no-cache chrony ;;
    esac
  fi
  command -v chronyd >/dev/null && command -v chronyc >/dev/null || die '未找到 chronyd / chronyc，无法配置自动校时。'

  # Keep the distribution's Chrony configuration and existing time sources.
  # Run one clock service to avoid competing adjustments.
  if [[ $INIT_SYSTEM == openrc ]]; then
    for other in ntpd openntpd; do
      if rc-service "$other" status >/dev/null 2>&1; then
        rc-service "$other" stop
        rc-update del "$other" default || true
      fi
    done
  else
    if [[ $PACKAGE_MANAGER == apt ]]; then unit=chrony.service; fi
    for other in systemd-timesyncd.service ntp.service ntpd.service openntpd.service; do
      if systemctl is-active --quiet "$other" || systemctl is-enabled --quiet "$other" 2>/dev/null; then
        systemctl disable --now "$other"
      fi
    done
  fi
  svc enable "$unit"
  # Do not restart a running daemon: retain its measurements and frequency estimate.
  if ! svc is-active "$unit"; then svc start "$unit"; fi
  chronyc online
  chronyc burst 4/4
  chronyc makestep
  say '正在等待时间同步（最多约 20 秒）……'
  if ! chronyc waitsync 20 0.1 0 1; then
    chronyc tracking || true
    chronyc sources -v || true
    die 'Chrony 已启用，但尚未确认同步；请检查时间源、DNS 和出站 UDP 123 后重试。'
  fi
  say '自动校时已启用并设置开机自启，当前时间同步检查通过（剩余修正量小于 0.1 秒）。'
  say 'Chrony 会持续在后台自动校准，无需额外添加每小时或每天的定时任务。'
  chronyc tracking
}

main() {
  local command_name=${1:-help} domain requested_entry
  if (($# == 0)); then
    interactive_menu || return 0
    command_name=$MENU_COMMAND
  fi
  (($# == 0)) || shift
  if [[ $command_name == help || $command_name == --help || $command_name == -h ]]; then usage; return; fi
  parse_options "$@"
  if [[ $command_name != install ]]; then
    [[ -z $SERVER_ADDR && -z $REALITY_PORT && -z $PUBLIC_PORT && -z $WS_PORT && -z $METRICS_PORT && -z $REALITY_SNI && -z $TUNNEL_PROTOCOL && -z $XRAY_VERSION && -z $CF_VERSION && -z $HY2_PORT && -z $HY2_PUBLIC_PORT && -z $SUB_PORT && -z $SUB_PUBLIC_PORT && -z $HY2_VERSION && -z $NODE_COUNTRY ]] || die 'Server settings and versions may only be changed with install.'
    [[ $command_name == set-entry || -z $CF_ENTRY ]] || die '--cf-entry is used with install or set-entry.'
  fi
  [[ $command_name == socks5 || ( -z $SOCKS_PORT && -z $SOCKS_PUBLIC_PORT ) ]] || die 'SOCKS5 port options may only be used with socks5.'
  [[ $command_name == mtproto || ( -z $MT_PORT && -z $MT_PUBLIC_PORT ) ]] || die "MTProto port options may only be used with mtproto."
  need_root
  check_platform
  trap cleanup EXIT
  if [[ $command_name == install ]]; then install_dependencies; fi
  command -v flock >/dev/null || die 'util-linux/flock is required.'
  mkdir -p /run/lock
  exec 9>/run/lock/personal-vpn-stack.lock
  flock -n 9 || die 'Another stack command is running.'
  trap cleanup EXIT
  trap 'on_error "$?" "$LINENO"' ERR
  case $command_name in
    install) install_stack ;;
    time-sync) configure_time_sync ;;
    uninstall) uninstall_stack ;;
    mtproto|mtproto-info|socks5|socks5-info|export|status|restart-tunnel|set-entry|stop)
      if [[ $command_name == mtproto || $command_name == mtproto-info ]]; then
        [[ -r "$ETC_DIR/managed-by" ]] || die '尚未完成基础服务安装。请先在菜单选择第一项“安装 / 更新（Cloudflare + Hy2）”，成功后再安装 MTProto；若此前出现 APT 404，请先解决依赖下载错误。'
      fi
      need_installation
      command -v jq >/dev/null || die 'jq is required.'
      requested_entry=$CF_ENTRY
      load_settings
      validate_settings
      case $command_name in
        mtproto) install_mtproto ;;
        mtproto-info) show_mtproto ;;
        socks5) install_socks5 ;;
        socks5-info) show_socks5 ;;
        export)
          domain=$(current_domain || true)
          export_nodes "$domain" ;;
        status)
          svc status "$VPN_UNIT" "$CF_UNIT"
          if [[ -f $(service_file "$HY2_UNIT") ]]; then svc status "$HY2_UNIT" "$SUB_UNIT"; fi
          if [[ -f $(service_file "$MT_UNIT") ]]; then svc status "$MT_UNIT"; fi
          domain=$(current_domain || true)
          say "Current temporary hostname: ${domain:-unavailable}"
          curl -fsS --max-time 3 "http://127.0.0.1:$METRICS_PORT/ready" || true
          printf '\n' ;;
        restart-tunnel)
          svc start "$VPN_UNIT"
          svc restart "$CF_UNIT"
          wait_tunnel || die 'Tunnel is not ready; inspect its service journal.'
          export_nodes "$CURRENT_DOMAIN" ;;
        set-entry)
          [[ -n $requested_entry ]] || die 'Specify --cf-entry IP_OR_HOST_OR_auto.'
          make_workdir
          jq --arg entry "$CF_ENTRY" '.cf_entry=$entry' "$ETC_DIR/settings.json" > "$WORK_DIR/settings.json"
          install -m 0600 "$WORK_DIR/settings.json" "$ETC_DIR/settings.json"
          if [[ -f "$ETC_DIR/subscription.json" ]]; then write_subscription_config; fi
          domain=$(current_domain || true)
          [[ -n $domain ]] || die 'Entry saved; start the tunnel and export links with restart-tunnel.'
          export_nodes "$domain"
          say "CF 入口已更改为 $CF_ENTRY:443。请在客户端更新订阅后重新连接 CF 节点。" ;;
        stop)
          if [[ -f $(service_file "$MT_UNIT") ]]; then svc stop "$MT_UNIT"; fi
          svc stop "$SUB_UNIT" "$HY2_UNIT" "$CF_UNIT" "$VPN_UNIT"; say 'Stopped. Keys and files retained.' ;;
      esac ;;
    *) die "Unknown command: $command_name (use help)." ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
