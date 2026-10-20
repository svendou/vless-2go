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
SERVICE_USER=personal-vpn-stack
UNIT_DIR=/etc/systemd/system
INIT_SYSTEM=systemd
PACKAGE_MANAGER=apt
RUN_DIR=/run/personal-vpn-stack
MARKER=personal-vpn-stack-v1
WORK_DIR=
INSTALL_TRANSACTION=0
VPN_WAS_ACTIVE=0
CF_WAS_ACTIVE=0
INTERACTIVE_INSTALL=0
SERVER_ADDR= REALITY_PORT= PUBLIC_PORT= WS_PORT= METRICS_PORT= REALITY_SNI=
CF_ENTRY= TUNNEL_PROTOCOL= XRAY_VERSION= CF_VERSION= OUTPUT_DIR=
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
  install          Install, or update this script's own installation.
  export           Export direct + Cloudflare links and QR PNGs.
  status           Show service state and tunnel readiness.
  restart-tunnel   Restart Quick Tunnel, then export its NEW hostname.
  set-entry        Change client entry address, then export links.
  stop             Stop this stack's two services; keep keys and files.
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
  local -a labels=('安装 / 更新' '查看共用节点' '重建临时隧道并查看新节点' '查看运行状态' '卸载' '退出')
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
  printf '其他设置使用默认值；安装后 Windows、iPhone、Mac 共用一条主线链接。\n\n'
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
      --server|--reality-port|--public-port|--ws-port|--metrics-port|--reality-sni|--cf-entry|--tunnel-protocol|--xray-version|--cloudflared-version|--output)
        (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
        case "$1" in
          --server) SERVER_ADDR=$2 ;; --reality-port) REALITY_PORT=$2 ;;
          --public-port) PUBLIC_PORT=$2 ;;
          --ws-port) WS_PORT=$2 ;; --metrics-port) METRICS_PORT=$2 ;;
          --reality-sni) REALITY_SNI=$2 ;; --cf-entry) CF_ENTRY=$2 ;;
          --tunnel-protocol) TUNNEL_PROTOCOL=$2 ;; --xray-version) XRAY_VERSION=$2 ;;
          --cloudflared-version) CF_VERSION=$2 ;; --output) OUTPUT_DIR=$2 ;;
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
  for port in "$REALITY_PORT" "$PUBLIC_PORT" "$WS_PORT" "$METRICS_PORT"; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port >= 1024 && port <= 65535)) || die 'Ports must be decimal integers between 1024 and 65535.'
  done
  [[ $REALITY_PORT != "$WS_PORT" && $REALITY_PORT != "$METRICS_PORT" && $WS_PORT != "$METRICS_PORT" ]] || die 'The three listening ports must differ.'
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
  for cmd in curl unzip openssl jq setpriv flock ss useradd getent qrencode; do
    command -v "$cmd" >/dev/null || missing=1
  done
  if ((missing)); then
    say 'Installing small prerequisite packages.'
    if [[ $PACKAGE_MANAGER == apk ]]; then
      apk add --no-cache bash ca-certificates curl unzip openssl jq setpriv flock \
        iproute2 shadow coreutils
      # QR encoding is optional and may require Alpine's community repository.
      if ! command -v qrencode >/dev/null; then
        apk add --no-cache libqrencode-tools || say 'QR package unavailable; node links will still be exported.'
      fi
    else
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl unzip openssl jq util-linux iproute2 passwd qrencode
    fi
  fi
  for cmd in curl unzip openssl jq setpriv flock ss useradd groupadd userdel groupdel getent install; do
    command -v "$cmd" >/dev/null || die "Required command unavailable after dependency installation: $cmd"
  done
}

service_file() {
  if [[ $INIT_SYSTEM == openrc ]]; then printf '%s/%s\n' "$UNIT_DIR" "${1%.service}"
  else printf '%s/%s\n' "$UNIT_DIR" "$1"; fi
}

svc() {
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
}

tunnel_logs() {
  if [[ $INIT_SYSTEM == openrc ]]; then
    [[ ! -r "$RUN_DIR/cloudflare.log" ]] || tail -n 15 "$RUN_DIR/cloudflare.log" >&2
  else
    journalctl -u "$CF_UNIT" -n 15 --no-pager >&2 || true
  fi
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

check_ports() {
  local port key old_port owner
  for key in reality_port ws_port metrics_port; do
    case $key in reality_port) port=$REALITY_PORT ;; ws_port) port=$WS_PORT ;; metrics_port) port=$METRICS_PORT ;; esac
    if ss -H -ltn "sport = :$port" | grep -q .; then
      old_port=
      [[ ! -r "$ETC_DIR/settings.json" ]] || old_port=$(setting "$key" '')
      if [[ $key == metrics_port ]]; then owner=$CF_UNIT; else owner=$VPN_UNIT; fi
      if [[ $port != "$old_port" ]] || ! svc is-active "$owner"; then
        die "TCP port $port is occupied by another service. Choose unused ports; existing services were not changed."
      fi
    fi
  done
}

backup_managed_files() {
  local file
  MANAGED_FILES=("$BIN_DIR/xray" "$BIN_DIR/cloudflared" "$ETC_DIR/settings.json" \
    "$ETC_DIR/identities.json" "$ETC_DIR/xray.json" \
    "$(service_file "$VPN_UNIT")" "$(service_file "$CF_UNIT")")
  mkdir -p "$WORK_DIR/backup"
  for file in "${MANAGED_FILES[@]}"; do
    [[ ! -e $file ]] || cp -a --parents "$file" "$WORK_DIR/backup"
  done
  if svc is-active "$VPN_UNIT"; then VPN_WAS_ACTIVE=1; fi
  if svc is-active "$CF_UNIT"; then CF_WAS_ACTIVE=1; fi
  INSTALL_TRANSACTION=1
}

rollback() {
  local file
  ((INSTALL_TRANSACTION)) || return 0
  INSTALL_TRANSACTION=0
  say "Installation failed; restoring only this script's managed files."
  svc stop "$CF_UNIT" "$VPN_UNIT" >/dev/null 2>&1 || true
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
  say 'Restarted Quick Tunnels may have a different hostname; export links again after recovery.'
}

on_error() {
  local code=$1 line=$2
  trap - ERR
  set +e
  printf '[vpn] Failed near line %s (exit %s).\n' "$line" "$code" >&2
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
    return
  fi
  output=$("$BIN_DIR/xray" x25519)
  private=$(awk '/^PrivateKey:/{print $NF}' <<<"$output")
  public=$(awk '/^(Password|PublicKey)/{print $NF;exit}' <<<"$output")
  [[ -n $private && -n $public ]] || die 'Unrecognized x25519 output.'
  uuid=$("$BIN_DIR/xray" uuid)
  jq -n --arg private "$private" --arg public "$public" --arg sid "$(openssl rand -hex 8)" \
    --arg path "/cf-$(openssl rand -hex 12)" \
    --arg uuid "$uuid" \
    '{schema:2,private_key:$private,public_key:$public,short_id:$sid,ws_path:$path,
      account:{direct:$uuid,cloudflare:$uuid}}' \
    > "$ETC_DIR/identities.json"
  chmod 0600 "$ETC_DIR/identities.json"
}

write_settings() {
  jq -n --arg server "$SERVER_ADDR" --argjson rp "$REALITY_PORT" --argjson pp "$PUBLIC_PORT" --argjson wp "$WS_PORT" \
    --argjson mp "$METRICS_PORT" --arg sni "$REALITY_SNI" --arg entry "$CF_ENTRY" \
    --arg protocol "$TUNNEL_PROTOCOL" --arg xv "$XRAY_VERSION" --arg cv "$CF_VERSION" \
    '{schema:1,server:$server,reality_port:$rp,public_port:$pp,ws_port:$wp,metrics_port:$mp,reality_sni:$sni,
      cf_entry:$entry,tunnel_protocol:$protocol,xray_version:$xv,cloudflared_version:$cv}' \
    > "$ETC_DIR/settings.json"
  chmod 0600 "$ETC_DIR/settings.json"
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
ExecStart=/usr/bin/setpriv --reuid=$SERVICE_USER --regid=$SERVICE_USER --clear-groups --bounding-set=-all --no-new-privs $BIN_DIR/cloudflared tunnel --url http://127.0.0.1:$WS_PORT --no-autoupdate --protocol $TUNNEL_PROTOCOL --edge-ip-version 4 --metrics 127.0.0.1:$METRICS_PORT --loglevel info
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
UMask=0077
LimitNOFILE=16384
UNIT
  chmod 0644 "$UNIT_DIR/$VPN_UNIT" "$UNIT_DIR/$CF_UNIT"
}

render_openrc_units() {
  local unit binary arguments logfile service_path
  for unit in "$VPN_UNIT" "$CF_UNIT"; do
    if [[ $unit == "$VPN_UNIT" ]]; then
      binary="$BIN_DIR/xray"
      arguments="run -config $ETC_DIR/xray.json"
      logfile=xray.log
    else
      binary="$BIN_DIR/cloudflared"
      arguments="tunnel --url http://127.0.0.1:$WS_PORT --no-autoupdate --protocol $TUNNEL_PROTOCOL --edge-ip-version 4 --metrics 127.0.0.1:$METRICS_PORT --loglevel info"
      logfile=cloudflare.log
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
respawn_period=0
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
  checkpath --directory --mode 0700 --owner root:root "$RUN_DIR" || return 1
  : > "$RUN_DIR/$logfile"
  chmod 0600 "$RUN_DIR/$logfile"
  ulimit -n 16384 2>/dev/null || true
}
UNIT
    chmod 0755 "$service_path"
  done
}

current_domain() {
  local pid
  if [[ $INIT_SYSTEM == openrc ]]; then
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
  local domain=$1 entry=$CF_ENTRY direct_id cf_id public sid path direct_link cf_link file export_tmp title
  [[ $entry != auto ]] || entry=$domain
  valid_host "$domain" || die 'No valid current tunnel hostname.'
  [[ ! -L $OUTPUT_DIR ]] || die 'Export directory must not be a symlink.'
  if [[ -d $OUTPUT_DIR && ! -f "$OUTPUT_DIR/.personal-vpn-stack-exports" ]]; then
    [[ -z $(ls -A -- "$OUTPUT_DIR") ]] || die 'Choose an empty export directory; refusing to change an unrelated directory.'
  fi
  install -d -m 0700 "$OUTPUT_DIR"
  printf '%s\n' "$MARKER" > "$OUTPUT_DIR/.personal-vpn-stack-exports"
  export_tmp=$(mktemp -d "$OUTPUT_DIR/.export.XXXXXXXX")
  public=$(jq -er '.public_key' "$ETC_DIR/identities.json")
  sid=$(jq -er '.short_id' "$ETC_DIR/identities.json")
  path=$(urlencode "$(jq -er '.ws_path' "$ETC_DIR/identities.json")")
  direct_id=$(jq -er '(.account // .devices.windows).direct' "$ETC_DIR/identities.json")
  cf_id=$(jq -er '(.account // .devices.windows).cloudflare' "$ETC_DIR/identities.json")
  direct_link="vless://$direct_id@$SERVER_ADDR:$PUBLIC_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$public&sid=$sid&type=tcp&flow=xtls-rprx-vision#Private-REALITY-Shared"
  cf_link="vless://$cf_id@$entry:443?encryption=none&security=tls&sni=$domain&fp=chrome&alpn=http%2F1.1&type=ws&host=$domain&path=$path#Private-CF-Shared"
  printf '%s\n' "$direct_link" > "$export_tmp/REALITY-node.txt"
  printf '%s\n' "$cf_link" > "$export_tmp/CF-node.txt"
  printf '%s\n%s\n' "$cf_link" "$direct_link" > "$export_tmp/all-nodes.txt"
  printf '%s\n' "$domain" > "$export_tmp/current-tunnel-domain.txt"
  if command -v qrencode >/dev/null; then
    for file in "$export_tmp"/CF-*.txt "$export_tmp"/REALITY-*.txt; do
      tr -d '\r\n' < "$file" | qrencode -t PNG -s 6 -o "${file%.txt}.png"
    done
  fi
  for file in "$export_tmp"/*; do mv -f -- "$file" "$OUTPUT_DIR/"; done
  rmdir "$export_tmp"
  for title in Windows iPhone Mac; do
    rm -f -- "$OUTPUT_DIR/CF-$title.txt" "$OUTPUT_DIR/CF-$title.png" "$OUTPUT_DIR/REALITY-$title.txt" "$OUTPUT_DIR/REALITY-$title.png"
  done
  say "Client files: $OUTPUT_DIR"
  say "Current hostname: $domain (temporary; changes when the tunnel is recreated)."
  printf '\n主线链接（所有设备共用）：\n%s\n\n备用直连链接：\n%s\n' "$cf_link" "$direct_link"
}

install_stack() {
  local cf_restart=1
  check_platform
  [[ ! -L $ETC_DIR && ! -L $BIN_DIR ]] || die 'Managed directories must not be symlinks.'
  if [[ -d $ETC_DIR ]]; then
    [[ -r "$ETC_DIR/managed-by" && $(cat "$ETC_DIR/managed-by") == "$MARKER" ]] || die "Refusing to overwrite an unmanaged directory: $ETC_DIR"
  else
    [[ ! -e $(service_file "$VPN_UNIT") && ! -e $(service_file "$CF_UNIT") && ! -e $BIN_DIR ]] || die 'Unmanaged stack files already exist.'
  fi
  install_dependencies
  load_settings
  if ((INTERACTIVE_INSTALL)); then interactive_settings; fi
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
  ensure_identities
  write_settings
  render_xray_config
  "$BIN_DIR/xray" run -test -config "$ETC_DIR/xray.json"
  render_units
  if ! cmp -s "$(service_file "$CF_UNIT")" "$WORK_DIR/backup$(service_file "$CF_UNIT")"; then cf_restart=1; fi
  printf '%s\n' "$MARKER" > "$ETC_DIR/managed-by"
  svc reload
  svc restart "$VPN_UNIT"
  if ((cf_restart)); then svc restart "$CF_UNIT"; fi
  if ! wait_tunnel; then rollback; INSTALL_TRANSACTION=0; die 'Tunnel did not become ready. Check outbound DNS and TCP/UDP 7844 access.'; fi
  # Only REALITY autostarts. Quick Tunnel restart creates a new, unexported URL.
  svc enable "$VPN_UNIT"
  INSTALL_TRANSACTION=0
  export_nodes "$CURRENT_DOMAIN"
  say 'Installation is ready. This confirms service/tunnel readiness, not an end-to-end speed test.'
  say 'Only the REALITY service autostarts; Quick Tunnel must be restarted and re-exported after reboot.'
}

uninstall_stack() {
  local answer file title
  need_installation
  for file in "$ETC_DIR" "$BIN_DIR" "$DATA_DIR" "$DATA_DIR/clients"; do
    [[ ! -L $file ]] || die "拒绝卸载符号链接目录：$file"
  done
  printf '\n将停止并删除本脚本的两个服务、程序、账号配置及默认目录中的节点文件。\nSSH、防火墙及手工部署的旧服务不受影响。\n'
  read -r -p '确认卸载？输入 y 继续 [N]：' answer || return 0
  [[ $answer == y || $answer == Y ]] || { say '已取消卸载。'; return 0; }
  svc stop "$CF_UNIT" "$VPN_UNIT"
  svc disable "$CF_UNIT" "$VPN_UNIT" >/dev/null 2>&1 || true
  rm -f -- "$(service_file "$CF_UNIT")" "$(service_file "$VPN_UNIT")"
  svc reload
  svc reset-failed "$CF_UNIT" "$VPN_UNIT" >/dev/null 2>&1 || true
  rm -rf -- "$BIN_DIR" "$ETC_DIR"
  if [[ -f "$DATA_DIR/clients/.personal-vpn-stack-exports" ]] &&
     [[ $(cat "$DATA_DIR/clients/.personal-vpn-stack-exports") == "$MARKER" ]]; then
    for title in node Windows iPhone Mac; do
      rm -f -- "$DATA_DIR/clients/CF-$title.txt" "$DATA_DIR/clients/CF-$title.png" \
        "$DATA_DIR/clients/REALITY-$title.txt" "$DATA_DIR/clients/REALITY-$title.png"
    done
    rm -f -- "$DATA_DIR/clients/all-nodes.txt" "$DATA_DIR/clients/current-tunnel-domain.txt" "$DATA_DIR/clients/.personal-vpn-stack-exports"
    rmdir -- "$DATA_DIR/clients" 2>/dev/null || true
  fi
  rmdir -- "$DATA_DIR" 2>/dev/null || true
  if id "$SERVICE_USER" >/dev/null 2>&1; then userdel "$SERVICE_USER"; fi
  if getent group "$SERVICE_USER" >/dev/null; then groupdel "$SERVICE_USER"; fi
  if [[ $INIT_SYSTEM == openrc && ! -L $RUN_DIR ]]; then
    rm -f -- "$RUN_DIR/cloudflare.log" "$RUN_DIR/xray.log" "$RUN_DIR/${VPN_UNIT%.service}.pid" "$RUN_DIR/${CF_UNIT%.service}.pid"
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
    [[ -z $SERVER_ADDR && -z $REALITY_PORT && -z $PUBLIC_PORT && -z $WS_PORT && -z $METRICS_PORT && -z $REALITY_SNI && -z $TUNNEL_PROTOCOL && -z $XRAY_VERSION && -z $CF_VERSION ]] || die 'Server settings and versions may only be changed with install.'
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
          [[ -n $domain ]] || die 'Tunnel is stopped or current logs are unavailable. Use restart-tunnel.'
          export_nodes "$domain" ;;
        status)
          svc status "$VPN_UNIT" "$CF_UNIT"
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
          domain=$(current_domain || true)
          [[ -n $domain ]] || die 'Entry saved; start the tunnel and export links with restart-tunnel.'
          export_nodes "$domain" ;;
        stop) svc stop "$CF_UNIT" "$VPN_UNIT"; say 'Stopped. Keys and files retained.' ;;
      esac ;;
    *) die "Unknown command: $command_name (use help)." ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
