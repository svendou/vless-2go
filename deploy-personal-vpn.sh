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
# Debian/Ubuntu + systemd, or Alpine + OpenRC.
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
SERVICE_USER=personal-vpn-stack
UNIT_DIR=/etc/systemd/system
INIT_SYSTEM=systemd
PACKAGE_MANAGER=apt
RUN_DIR=/run/personal-vpn-stack
MARKER=personal-vpn-stack-v1
WORK_DIR=
INSTALL_TRANSACTION=0
FAILURE_LOG=
VPN_WAS_ACTIVE=0
CF_WAS_ACTIVE=0
HY2_WAS_ACTIVE=0
SUB_WAS_ACTIVE=0
INTERACTIVE_INSTALL=0
SERVER_ADDR= REALITY_PORT= PUBLIC_PORT= WS_PORT= METRICS_PORT= REALITY_SNI=
CF_ENTRY= TUNNEL_PROTOCOL= XRAY_VERSION= CF_VERSION= OUTPUT_DIR=
HY2_PORT= HY2_PUBLIC_PORT= SUB_PORT= SUB_PUBLIC_PORT= HY2_VERSION= NODE_COUNTRY=
MANAGED_FILES=()

say() { printf '[vpn] %s\n' "$*"; }
die() {
  printf '[vpn] ERROR: %s\n' "$*" >&2
  if ((INSTALL_TRANSACTION)); then rollback; fi
  exit 1
}

usage() {
  cat <<'HELP'
Usage: bash deploy-personal-vpn.sh COMMAND [OPTIONS]
       sh deploy-personal-vpn.sh      # Menu; installs Bash on Alpine if needed.

Commands:
  install          Install/update Cloudflare, REALITY, Hy2 and subscription together.
  export           Show ONE subscription URL; also save individual links and QR PNGs.
  status           Show service state and tunnel readiness.
  restart-tunnel   Restart Quick Tunnel, then export its NEW hostname.
  set-entry        Change client entry address, then export links.
  stop             Stop this stack's four services; keep keys and files.
  uninstall        Remove this script's installation (asks for confirmation).
  help             Show this help.

Options:
  --server HOST             Public IPv4 address or DNS name (fresh install).
  --reality-port PORT       Internal direct port (default 43526).
  --public-port PORT        Public direct port (default: same as internal).
  --ws-port PORT            Loopback WebSocket port (default 48089).
  --metrics-port PORT       Loopback health port (default 48090).
  --reality-sni HOST        REALITY handshake target (default www.cloudflare.com).
  --cf-entry HOST           Cloudflare IP/hostname, or auto (default auto).
  --tunnel-protocol NAME    http2 (default) or quic, server-to-Cloudflare only.
  --xray-version TAG        Default v26.3.27; accepts latest.
  --cloudflared-version TAG Default 2026.10.1; accepts latest.
  --hy2-port PORT           Hy2 internal UDP port (default 43526).
  --hy2-public-port PORT    Hy2 public UDP port (default: same as internal).
  --subscription-port PORT Subscription internal TCP port (default 43518).
  --subscription-public-port PORT  Public subscription TCP port (default: internal).
  --hy2-version TAG         Default app/v2.13.0; accepts latest.
  --country CC              Node country prefix, e.g. US (default: detect automatically).
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

interactive_menu() {
  local selected=0 index key sequence
  local -a labels=('安装 / 更新（Cloudflare + Hy2）' '查看订阅链接' '重建临时隧道并更新订阅' '查看运行状态' '卸载' '退出')
  [[ -t 0 ]] || die '请在交互终端直接运行脚本，或使用 help 查看命令。'
  printf '\n'
  while :; do
    printf '\r\033[2K个人节点部署\n'
    for index in "${!labels[@]}"; do
      if ((index == selected)); then
        printf '\r\033[2K\033[1;36m  > %s\033[0m\n' "${labels[index]}"
      else
        printf '\r\033[2K    %s\n' "${labels[index]}"
      fi
    done
    printf '\r\033[2K↑ / ↓ 选择，Enter 确认，q 退出\n'
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
    printf '\033[8A'
  done
  case $selected in
    0) MENU_COMMAND=install; INTERACTIVE_INSTALL=1 ;;
    1) MENU_COMMAND=export ;;
    2) MENU_COMMAND=restart-tunnel ;;
    3) MENU_COMMAND=status ;;
    4) MENU_COMMAND=uninstall ;;
    5) return 1 ;;
  esac
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
  prompt_value CF_ENTRY 'Cloudflare 入口（auto 为自动，可填优选 IP）' "$CF_ENTRY"
  prompt_value HY2_PORT 'Hy2 内部 UDP 端口' "$HY2_PORT"
  if [[ ! -r "$ETC_DIR/settings.json" ]] || ! jq -e 'has("hy2_public_port")' "$ETC_DIR/settings.json" >/dev/null; then HY2_PUBLIC_PORT=$HY2_PORT; fi
  prompt_value HY2_PUBLIC_PORT 'Hy2 公网 UDP 端口' "$HY2_PUBLIC_PORT"
  prompt_value SUB_PORT '订阅内部 TCP 端口' "$SUB_PORT"
  if [[ ! -r "$ETC_DIR/settings.json" ]] || ! jq -e 'has("subscription_public_port")' "$ETC_DIR/settings.json" >/dev/null; then SUB_PUBLIC_PORT=$SUB_PORT; fi
  prompt_value SUB_PUBLIC_PORT '订阅公网 TCP 端口' "$SUB_PUBLIC_PORT"
  printf '其他设置使用默认值；所有设备共用一个订阅地址，内含 CF、Hy2 和 REALITY。\n\n'
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
      --server|--reality-port|--public-port|--ws-port|--metrics-port|--reality-sni|--cf-entry|--tunnel-protocol|--xray-version|--cloudflared-version|--output|--hy2-port|--hy2-public-port|--subscription-port|--subscription-public-port|--hy2-version|--country)
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
    CF_ENTRY=${CF_ENTRY:-$(setting cf_entry auto)}
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
  CF_ENTRY=${CF_ENTRY:-auto}
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
  [[ -z $NODE_COUNTRY || $NODE_COUNTRY =~ ^[A-Z]{2}$ ]] || die '--country must be a two-letter uppercase code, e.g. US.'
  [[ $HY2_VERSION == latest || $HY2_VERSION =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die 'Invalid Hy2 release tag.'
  [[ $XRAY_VERSION =~ ^[A-Za-z0-9._-]+$ && $CF_VERSION =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid release tag.'
  [[ $OUTPUT_DIR == /* && $OUTPUT_DIR != / && $OUTPUT_DIR != *$'\n'* ]] || die '--output must be an absolute directory path.'
}

check_platform() {
  [[ -r /etc/os-release ]] || die 'Missing /etc/os-release.'
  local distro like
  distro=$(. /etc/os-release; printf '%s' "$ID")
  like=$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")
  if [[ $distro == alpine ]]; then
    PACKAGE_MANAGER=apk
    INIT_SYSTEM=openrc
    UNIT_DIR=/etc/init.d
    command -v apk >/dev/null || die 'apk not found.'
    command -v rc-service >/dev/null && [[ -d /run/openrc ]] || die 'Alpine requires a running OpenRC environment; plain Docker/chroot environments need OpenRC setup first.'
  elif [[ $distro == debian || $distro == ubuntu || " $like " == *' debian '* ]]; then
    PACKAGE_MANAGER=apt
    INIT_SYSTEM=systemd
    UNIT_DIR=/etc/systemd/system
    command -v apt-get >/dev/null || die 'apt-get not found.'
    systemctl show-environment >/dev/null 2>&1 || die 'A working systemd system manager is required.'
  else
    die 'Supported systems: Debian/Ubuntu with systemd, Alpine with OpenRC.'
  fi
}

install_dependencies() {
  local missing=0 cmd
  for cmd in curl unzip openssl jq setpriv flock ss useradd getent qrencode python3; do
    command -v "$cmd" >/dev/null || missing=1
  done
  if ((missing)); then
    say 'Installing small prerequisite packages.'
    if [[ $PACKAGE_MANAGER == apk ]]; then
      apk add --no-cache bash ca-certificates curl unzip openssl jq setpriv flock \
        iproute2 shadow coreutils python3
      # QR encoding is optional and may require Alpine's community repository.
      if ! command -v qrencode >/dev/null; then
        apk add --no-cache libqrencode-tools || say 'QR package unavailable; node links will still be exported.'
      fi
    else
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl unzip openssl jq util-linux iproute2 passwd qrencode python3
    fi
  fi
  for cmd in curl unzip openssl jq setpriv flock ss useradd groupadd userdel groupdel getent install python3; do
    command -v "$cmd" >/dev/null || die "Required command unavailable after dependency installation: $cmd"
  done
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
    for file in "$WORK_DIR"/start-*.log; do
      if [[ -f $file ]]; then
        printf '\nService startup output: %s\n' "${file##*/}"
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
  if [[ -n $WORK_DIR && $WORK_DIR == /var/tmp/personal-vpn-stack.* ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

download_asset() {
  local repo=$1 tag=$2 asset=$3 destination=$4 endpoint metadata asset_json url digest expected
  if [[ $tag == latest ]]; then endpoint=latest; else endpoint="tags/$tag"; fi
  metadata="$WORK_DIR/$(basename "$destination").release.json"
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
    -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/releases/$endpoint" -o "$metadata"
  asset_json=$(jq -ce --arg name "$asset" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else error("asset not found") end' "$metadata")
  url=$(jq -er '.browser_download_url' <<<"$asset_json")
  digest=$(jq -r '.digest // empty' <<<"$asset_json")
  [[ $url == https://github.com/* ]] || die 'Unexpected release download URL.'
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 "$url" -o "$destination"
  if [[ $digest =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
    expected=${BASH_REMATCH[1]}
  elif [[ $repo == XTLS/Xray-core ]]; then
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "$url.dgst" -o "$destination.dgst"
    expected=$(awk '/^SHA2-256=/{print $2}' "$destination.dgst")
  else
    die 'No official SHA-256 digest found; refusing unverified installation.'
  fi
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die 'Invalid release digest.'
  printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status || die 'Download checksum mismatch.'
  RESOLVED_TAG=$(jq -er '.tag_name' "$metadata")
}

stage_binaries() {
  local xray_asset cf_asset hy2_asset
  case $(uname -m) in
    x86_64|amd64) xray_asset=Xray-linux-64.zip; cf_asset=cloudflared-linux-amd64; hy2_asset=hysteria-linux-amd64 ;;
    aarch64|arm64) xray_asset=Xray-linux-arm64-v8a.zip; cf_asset=cloudflared-linux-arm64; hy2_asset=hysteria-linux-arm64 ;;
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
  download_asset apernet/hysteria "$HY2_VERSION" "$hy2_asset" "$WORK_DIR/hysteria"
  HY2_VERSION=$RESOLVED_TAG
  chmod 0755 "$WORK_DIR/hysteria"
  "$WORK_DIR/hysteria" version
}

check_ports() {
  local port key old_port owner
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
      die "UDP port $HY2_PORT is occupied by another service."
    fi
  fi
}

backup_managed_files() {
  local file
  MANAGED_FILES=("$BIN_DIR/xray" "$BIN_DIR/cloudflared" "$BIN_DIR/hysteria" "$BIN_DIR/subscription.py" \
    "$ETC_DIR/settings.json" "$ETC_DIR/identities.json" "$ETC_DIR/xray.json" \
    "$ETC_DIR/hy2.json" "$ETC_DIR/hy2.crt" "$ETC_DIR/hy2.key" "$ETC_DIR/subscription.json" \
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
    --arg hv "$HY2_VERSION" --arg country "$NODE_COUNTRY" \
    '{schema:1,server:$server,reality_port:$rp,public_port:$pp,ws_port:$wp,metrics_port:$mp,reality_sni:$sni,
      cf_entry:$entry,tunnel_protocol:$protocol,xray_version:$xv,cloudflared_version:$cv,
      hy2_port:$hp,hy2_public_port:$hpp,subscription_port:$sp,subscription_public_port:$spp,hy2_version:$hv,node_country:$country}' \
    > "$ETC_DIR/settings.json"
  chmod 0600 "$ETC_DIR/settings.json"
}

ensure_hy2_certificate() {
  if [[ ! -f "$ETC_DIR/hy2.crt" || ! -f "$ETC_DIR/hy2.key" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj '/CN=hy2.local' -addext 'subjectAltName=DNS:hy2.local' \
      -keyout "$ETC_DIR/hy2.key" -out "$ETC_DIR/hy2.crt" >/dev/null 2>&1
  fi
  openssl x509 -in "$ETC_DIR/hy2.crt" -noout -checkend 0 >/dev/null || die 'Hy2 certificate has expired.'
  [[ $(openssl x509 -in "$ETC_DIR/hy2.crt" -pubkey -noout | openssl sha256) == \
     $(openssl pkey -in "$ETC_DIR/hy2.key" -pubout | openssl sha256) ]] || die 'Hy2 certificate/key mismatch.'
  chown root:"$SERVICE_USER" "$ETC_DIR/hy2.crt" "$ETC_DIR/hy2.key"
  chmod 0640 "$ETC_DIR/hy2.crt" "$ETC_DIR/hy2.key"
}

render_hy2_config() {
  jq --arg listen "0.0.0.0:$HY2_PORT" --arg cert "$ETC_DIR/hy2.crt" --arg key "$ETC_DIR/hy2.key" \
    '{listen:$listen,tls:{cert:$cert,key:$key},auth:{type:"password",password:.hy2_password}}' \
    "$ETC_DIR/identities.json" > "$ETC_DIR/hy2.json"
  chown root:"$SERVICE_USER" "$ETC_DIR/hy2.json"
  chmod 0640 "$ETC_DIR/hy2.json"
}

write_subscription_config() {
  local pin file
  pin=$(openssl x509 -in "$ETC_DIR/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':\r\n' | tr 'A-F' 'a-f')
  file=$(mktemp "$ETC_DIR/.subscription.XXXXXXXX")
  jq -s --arg pin "$pin" --arg logs "$RUN_DIR/cloudflare.log" \
    '.[0] + {identities:.[1],hy2_pin:$pin,cf_log:$logs}' \
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
    params = {"sni": "hy2.local", "insecure": "1", "pinSHA256": cfg["hy2_pin"]}
    result["Hy2"] = (f'hysteria2://{quote(ids["hy2_password"], safe="")}@{cfg["server"]}:'
                     f'{cfg["hy2_public_port"]}/?{urlencode(params)}#{quote(prefix + "-Hy2", safe="")}')
    params = {"encryption": "none", "security": "reality", "sni": cfg["reality_sni"],
              "fp": "chrome", "pbk": ids["public_key"], "sid": ids["short_id"],
              "type": "tcp", "flow": "xtls-rprx-vision"}
    result["REALITY"] = (f'vless://{account["direct"]}@{cfg["server"]}:{cfg["public_port"]}'
                         f'?{urlencode(params)}#{quote(prefix + "-REALITY", safe="")}')
    return result


def subscription_url(cfg):
    return f'http://{cfg["server"]}:{cfg["subscription_public_port"]}/{cfg["identities"]["subscription_token"]}'


def payload(cfg, domain):
    return base64.b64encode(("\n".join(nodes(cfg, domain).values()) + "\n").encode("utf-8"))


class SubscriptionHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.respond(False)

    def do_HEAD(self):
        self.respond(True)

    def respond(self, head_only):
        try:
            cfg = load_config(self.server.config_path)
            expected = "/" + cfg["identities"]["subscription_token"]
            if not hmac.compare_digest(urlsplit(self.path).path.encode(), expected.encode()):
                self.send_body(404, b"Not Found\n", head_only)
                return
            self.send_body(200, payload(cfg, current_domain(cfg)), head_only)
        except (OSError, ValueError, KeyError):
            self.send_body(503, b"Temporarily unavailable\n", head_only)

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
        (directory / "subscription-url.txt").write_text(subscription_url(cfg) + "\n", encoding="utf-8")
        (directory / "current-tunnel-domain.txt").write_text(domain + "\n", encoding="utf-8")
        print(subscription_url(cfg), flush=True)
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
  chown root:"$SERVICE_USER" "$ETC_DIR/xray.json"
  chmod 0640 "$ETC_DIR/xray.json"
}

render_units() {
  local unit binary arguments
  if [[ $INIT_SYSTEM == openrc ]]; then render_openrc_units; return; fi
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
ExecStart=/usr/bin/setpriv --reuid=$SERVICE_USER --regid=$SERVICE_USER --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/xray run -config $ETC_DIR/xray.json
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
After=network-online.target $VPN_UNIT
[Service]
Type=simple
Environment=GOMEMLIMIT=64MiB
Environment=GOGC=75
Environment=GOMAXPROCS=2
ExecStartPre=/usr/bin/install -d -m 0750 -o root -g $SERVICE_USER $RUN_DIR
ExecStartPre=/usr/bin/install -m 0640 -o root -g $SERVICE_USER /dev/null $RUN_DIR/cloudflare.log
# Open the log only after ExecStartPre creates its directory (also after reboot).
StandardOutput=journal
StandardError=journal
ExecStart=/bin/sh -c 'exec /usr/bin/setpriv --reuid=$SERVICE_USER --regid=$SERVICE_USER --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/cloudflared tunnel --url http://127.0.0.1:$WS_PORT --no-autoupdate --protocol $TUNNEL_PROTOCOL --edge-ip-version 4 --metrics 127.0.0.1:$METRICS_PORT --loglevel info >>$RUN_DIR/cloudflare.log 2>&1'
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
ExecStart=$(command -v setpriv) --reuid=$SERVICE_USER --regid=$SERVICE_USER --clear-groups --bounding-set=-all --no-new-privs $binary $arguments
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
  for unit in "$VPN_UNIT" "$CF_UNIT" "$HY2_UNIT" "$SUB_UNIT"; do
    if [[ $unit == "$VPN_UNIT" ]]; then
      binary="$BIN_DIR/xray"
      arguments="run -config $ETC_DIR/xray.json"
      logfile=xray.log
    elif [[ $unit == "$CF_UNIT" ]]; then
      binary="$BIN_DIR/cloudflared"
      arguments="tunnel --url http://127.0.0.1:$WS_PORT --no-autoupdate --protocol $TUNNEL_PROTOCOL --edge-ip-version 4 --metrics 127.0.0.1:$METRICS_PORT --loglevel info"
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
command_args="--reuid=$SERVICE_USER --regid=$SERVICE_USER --clear-groups --bounding-set=-all --no-new-privs $binary $arguments"
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
    if [[ $unit == "$CF_UNIT" ]]; then printf '  need %s\n' "${VPN_UNIT%.service}" >> "$service_path"; fi
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
  for file in "$export_tmp"/*; do mv -f -- "$file" "$OUTPUT_DIR/"; done
  rmdir "$export_tmp"
  say "Client files: $OUTPUT_DIR"
  printf '\n共用订阅链接（导入客户端的“订阅”功能）：\n%s\n' "$url"
  say '订阅包含 CF、Hy2、REALITY；尚未获取到 CF 域名时只列出直连节点。HTTP 订阅地址含访问密钥，请勿公开。'
}

install_stack() {
  local cf_restart=1
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
  backup_managed_files
  ensure_user
  install -d -m 0750 -o root -g "$SERVICE_USER" "$ETC_DIR"
  install -d -m 0755 "$BIN_DIR"
  install -d -m 0700 "$DATA_DIR"
  printf '%s\n' "$MARKER" > "$ETC_DIR/managed-by"
  if ((CF_WAS_ACTIVE)) && cmp -s "$WORK_DIR/cloudflared" "$BIN_DIR/cloudflared"; then cf_restart=0; fi
  install -m 0755 "$WORK_DIR/xray" "$BIN_DIR/xray"
  install -m 0755 "$WORK_DIR/cloudflared" "$BIN_DIR/cloudflared"
  install -m 0755 "$WORK_DIR/hysteria" "$BIN_DIR/hysteria"
  ensure_identities
  ensure_hy2_certificate
  write_settings
  render_xray_config
  render_hy2_config
  write_subscription_config
  render_subscription_server
  "$BIN_DIR/xray" run -test -config "$ETC_DIR/xray.json"
  render_units
  if ! cmp -s "$(service_file "$CF_UNIT")" "$WORK_DIR/backup$(service_file "$CF_UNIT")"; then cf_restart=1; fi
  printf '%s\n' "$MARKER" > "$ETC_DIR/managed-by"
  svc reload
  restart_service "$VPN_UNIT"
  restart_service "$HY2_UNIT"
  restart_service "$SUB_UNIT"
  if ((cf_restart)); then restart_service "$CF_UNIT"; fi
  if ! wait_tunnel; then collect_failure_diagnostics; rollback; INSTALL_TRANSACTION=0; die 'Tunnel did not become ready. Check outbound DNS and TCP/UDP 7844 access.'; fi
  if ! wait_subscription; then collect_failure_diagnostics; die 'Hy2/subscription failed to become ready.'; fi
  svc enable "$VPN_UNIT" "$CF_UNIT" "$HY2_UNIT" "$SUB_UNIT"
  INSTALL_TRANSACTION=0
  export_nodes "$CURRENT_DOMAIN"
  say 'Installation is ready. This confirms service/tunnel readiness, not an end-to-end speed test.'
  say '四个服务均已设置开机自启；临时域名变化后，刷新同一个订阅地址即可。'
  say "需要公网 TCP $SUB_PUBLIC_PORT → 内部 TCP $SUB_PORT，UDP $HY2_PUBLIC_PORT → 内部 UDP $HY2_PORT；REALITY 备用另需 TCP $PUBLIC_PORT → $REALITY_PORT。"
}

wait_subscription() {
  local token deadline
  token=$(jq -er '.subscription_token' "$ETC_DIR/identities.json")
  deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if svc is-active "$HY2_UNIT" && svc is-active "$SUB_UNIT" && \
       ss -H -lun "sport = :$HY2_PORT" | grep -q .; then
      if curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$SUB_PORT/$token" -o "$WORK_DIR/subscription-health.txt" && \
         python3 -c 'import base64,sys; x=base64.b64decode(open(sys.argv[1],"rb").read(),validate=True).decode(); assert "hysteria2://" in x and "vless://" in x' "$WORK_DIR/subscription-health.txt"; then
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
  printf '\n将卸载本脚本的 Cloudflare、REALITY、Hy2 和订阅服务，删除程序、账号配置及默认目录中的节点文件。\nSSH、防火墙及手工部署的旧服务不受影响。\n'
  read -r -p '确认卸载？输入 y 继续 [N]：' answer || return 0
  [[ $answer == y || $answer == Y ]] || { say '已取消卸载。'; return 0; }
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
      "$DATA_DIR/clients/subscription.txt" "$DATA_DIR/clients/subscription-url.txt" "$DATA_DIR/clients/subscription-url.png"
    rm -f -- "$DATA_DIR/clients/all-nodes.txt" "$DATA_DIR/clients/current-tunnel-domain.txt" "$DATA_DIR/clients/.personal-vpn-stack-exports"
    rmdir -- "$DATA_DIR/clients" 2>/dev/null || true
  fi
  rmdir -- "$DATA_DIR" 2>/dev/null || true
  if id "$SERVICE_USER" >/dev/null 2>&1; then userdel "$SERVICE_USER"; fi
  if getent group "$SERVICE_USER" >/dev/null; then groupdel "$SERVICE_USER"; fi
  if [[ $INIT_SYSTEM == openrc && ! -L $RUN_DIR ]]; then
    rm -f -- "$RUN_DIR/cloudflare.log" "$RUN_DIR/xray.log" "$RUN_DIR/hy2.log" "$RUN_DIR/subscription.log" \
      "$RUN_DIR/${VPN_UNIT%.service}.pid" "$RUN_DIR/${CF_UNIT%.service}.pid" "$RUN_DIR/${HY2_UNIT%.service}.pid" "$RUN_DIR/${SUB_UNIT%.service}.pid"
    rmdir -- "$RUN_DIR" 2>/dev/null || true
  fi
  say '卸载完成。自行复制或自定义目录导出的节点文件可自行删除。'
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
  need_root
  check_platform
  if [[ $command_name == install ]]; then install_dependencies; fi
  command -v flock >/dev/null || die 'util-linux/flock is required.'
  mkdir -p /run/lock
  exec 9>/run/lock/personal-vpn-stack.lock
  flock -n 9 || die 'Another stack command is running.'
  trap cleanup EXIT
  trap 'on_error "$?" "$LINENO"' ERR
  case $command_name in
    install) install_stack ;;
    uninstall) uninstall_stack ;;
    export|status|restart-tunnel|set-entry|stop)
      need_installation
      command -v jq >/dev/null || die 'jq is required.'
      requested_entry=$CF_ENTRY
      load_settings
      validate_settings
      case $command_name in
        export)
          domain=$(current_domain || true)
          export_nodes "$domain" ;;
        status)
          svc status "$VPN_UNIT" "$CF_UNIT"
          if [[ -f $(service_file "$HY2_UNIT") ]]; then svc status "$HY2_UNIT" "$SUB_UNIT"; fi
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
          export_nodes "$domain" ;;
        stop) svc stop "$SUB_UNIT" "$HY2_UNIT" "$CF_UNIT" "$VPN_UNIT"; say 'Stopped. Keys and files retained.' ;;
      esac ;;
    *) die "Unknown command: $command_name (use help)." ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
