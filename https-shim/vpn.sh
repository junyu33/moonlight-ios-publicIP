#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${WG_IFACE:=moonwg0}"
: "${LAN_IP:=10.0.42.1}"
: "${WG_CLIENT_ADDR:=10.0.42.2/32}"
: "${IOS_IP:=${WG_CLIENT_ADDR%%/*}}"

: "${HAPROXY_TLS_PORT:=48489}"
: "${SUNSHINE_HTTPS_PORT:=47984}"
: "${SUNSHINE_RTSP_PORT:=48010}"
: "${SUNSHINE_UDP_RANGE:=47998-48010}"

: "${NFT_COMMENT_PREFIX:=moonlight-ios-publicIP:https-shim:vpn}"

SUNSHINE_UDP_RANGE_START="${SUNSHINE_UDP_RANGE%-*}"
SUNSHINE_UDP_RANGE_END="${SUNSHINE_UDP_RANGE#*-}"

need_root_for() {
  case "${1:-}" in
    up|down)
      if [[ "${EUID}" -ne 0 ]]; then
        echo "Please run '$0 $1' as root, e.g. sudo $0 $1" >&2
        exit 1
      fi
      ;;
  esac
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

delete_filter_rules() {
  local handle
  while IFS= read -r handle; do
    [[ -n "$handle" ]] && nft delete rule inet filter input handle "$handle" 2>/dev/null || true
  done < <(nft -a list chain inet filter input 2>/dev/null | awk -v p="$NFT_COMMENT_PREFIX" 'index($0, p) {print $NF}')
}

down() {
  nft delete table ip moonlight_vpn_https_nat 2>/dev/null || true
  delete_filter_rules
}

up() {
  down

  nft add table ip moonlight_vpn_https_nat
  nft 'add chain ip moonlight_vpn_https_nat prerouting { type nat hook prerouting priority dstnat; policy accept; }'

  nft add rule ip moonlight_vpn_https_nat prerouting \
    iifname "$WG_IFACE" ip saddr "$IOS_IP" tcp dport 47989 \
    redirect to :"$HAPROXY_TLS_PORT" \
    comment "\"$NFT_COMMENT_PREFIX:tls-47989\""

  nft add rule inet filter input \
    iifname "$WG_IFACE" ip saddr "$IOS_IP" tcp dport "$HAPROXY_TLS_PORT" \
    accept comment "\"$NFT_COMMENT_PREFIX:haproxy\""

  nft add rule inet filter input \
    iifname "$WG_IFACE" ip saddr "$IOS_IP" tcp dport "$SUNSHINE_HTTPS_PORT" \
    accept comment "\"$NFT_COMMENT_PREFIX:https\""

  nft add rule inet filter input \
    iifname "$WG_IFACE" ip saddr "$IOS_IP" tcp dport "$SUNSHINE_RTSP_PORT" \
    accept comment "\"$NFT_COMMENT_PREFIX:rtsp\""

  nft add rule inet filter input \
    iifname "$WG_IFACE" ip saddr "$IOS_IP" udp dport "$SUNSHINE_UDP_RANGE_START"-"$SUNSHINE_UDP_RANGE_END" \
    accept comment "\"$NFT_COMMENT_PREFIX:udp\""

  nft add rule inet filter input \
    iifname "$WG_IFACE" udp dport 53 \
    accept comment "\"$NFT_COMMENT_PREFIX:dns\""
}

list_rules() {
  nft -a list table ip moonlight_vpn_https_nat 2>/dev/null || true
  nft -a list chain inet filter input 2>/dev/null | grep -F "$NFT_COMMENT_PREFIX" || true
}

status() {
  cat <<EOF
WG_IFACE=$WG_IFACE
LAN_IP=$LAN_IP
WG_CLIENT_ADDR=$WG_CLIENT_ADDR
IOS_IP=$IOS_IP
HAPROXY_TLS_PORT=$HAPROXY_TLS_PORT
SUNSHINE_HTTPS_PORT=$SUNSHINE_HTTPS_PORT
SUNSHINE_RTSP_PORT=$SUNSHINE_RTSP_PORT
SUNSHINE_UDP_RANGE=$SUNSHINE_UDP_RANGE
NFT_COMMENT_PREFIX=$NFT_COMMENT_PREFIX
EOF
  echo
  list_rules
}

usage() {
  cat <<EOF
Usage:
  $0 up      Add temporary VPN fresh-add HTTPS shim rules
  $0 down    Remove temporary VPN fresh-add HTTPS shim rules
  $0 list    List temporary VPN fresh-add HTTPS shim rules
  $0 status  Print resolved config and list rules

Examples:
  sudo $0 up
  sudo $0 down
  $0 list
  $0 status
EOF
}

cmd="${1:-}"
need_root_for "$cmd"

case "$cmd" in
  up)
    need_cmd nft
    up
    ;;
  down)
    need_cmd nft
    down
    ;;
  list)
    need_cmd nft
    need_cmd grep
    list_rules
    ;;
  status)
    need_cmd nft
    need_cmd grep
    status
    ;;
  *)
    usage
    ;;
esac
