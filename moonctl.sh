#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${MOON_HOST:?Set MOON_HOST in .env}"
: "${LAN_IP:?Set LAN_IP in .env}"
: "${WG_IFACE:=moonwg0}"
: "${PUBLIC_IFACE:=enp3s0}"
: "${UPSTREAM_DNS:=8.8.8.8}"
: "${DNSMASQ_CONF:=/tmp/moon-dnsmasq.conf}"
: "${DNSMASQ_PID:=/tmp/moon-dnsmasq.pid}"
: "${DNSMASQ_LOG:=/tmp/moon-dnsmasq.log}"
: "${ADD_CAPTURE:=/tmp/moon-add.txt}"
: "${PUBLIC_CAPTURE:=/tmp/moon-public.txt}"
: "${NFT_COMMENT:=moonlight-ios-publicIP}"
: "${NFT_PUBLIC_COMMENT:=$NFT_COMMENT:public}"
: "${NFT_VPN_COMMENT:=$NFT_COMMENT:vpn}"

need_root_for() {
  case "${1:-}" in
    dns-start|dns-stop|firewall-open|firewall-close|firewall-list|vpn-firewall-open|vpn-firewall-close|vpn-firewall-list|capture-add|capture-public)
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

need_cmds_for() {
  case "${1:-}" in
    dns-start)
      need_cmd dnsmasq
      need_cmd pkill
      ;;
    dns-stop)
      need_cmd pkill
      ;;
    firewall-open|firewall-close|firewall-list|vpn-firewall-open|vpn-firewall-close|vpn-firewall-list)
      need_cmd nft
      ;;
    check)
      need_cmd ip
      need_cmd ss
      need_cmd dig
      need_cmd nft
      need_cmd grep
      ;;
    capture-add|capture-public)
      need_cmd tcpdump
      ;;
    grep-add|grep-public)
      need_cmd grep
      ;;
  esac
}

write_dnsmasq_conf() {
  cat > "$DNSMASQ_CONF" <<EOF
no-resolv
server=$UPSTREAM_DNS
interface=$WG_IFACE
listen-address=$LAN_IP
bind-dynamic
local=/$MOON_HOST/
address=/$MOON_HOST/$LAN_IP
log-queries
log-facility=$DNSMASQ_LOG
EOF
}

dns_kill_existing() {
  if [[ -f "$DNSMASQ_PID" ]]; then
    kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
  fi

  pkill -f "$DNSMASQ_CONF" 2>/dev/null || true
}

dns_remove_runtime_files() {
  rm -f "$DNSMASQ_PID" "$DNSMASQ_CONF" "$DNSMASQ_LOG"
}

dns_start() {
  dns_kill_existing
  dns_remove_runtime_files
  write_dnsmasq_conf

  dnsmasq \
    --conf-file="$DNSMASQ_CONF" \
    --pid-file="$DNSMASQ_PID"

  echo "dnsmasq started:"
  echo "  $MOON_HOST -> $LAN_IP"
  echo "  conf: $DNSMASQ_CONF"
  echo "  log:  $DNSMASQ_LOG"
}

dns_stop() {
  dns_kill_existing
  dns_remove_runtime_files
  echo "dnsmasq stopped"
}

firewall_rule_handles() {
  local comment="$1"
  local line
  nft -a list chain inet filter input 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == *"comment \"$comment\""* && "$line" =~ handle[[:space:]]+([0-9]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done
}

firewall_delete_by_comment() {
  local comment="$1"
  local handle
  while IFS= read -r handle; do
    nft delete rule inet filter input handle "$handle" 2>/dev/null || true
  done < <(firewall_rule_handles "$comment")
}

firewall_close() {
  firewall_delete_by_comment "$NFT_PUBLIC_COMMENT"
  firewall_delete_by_comment "$NFT_COMMENT"
  echo "Temporary public nftables rules removed from inet filter input"
}

firewall_open() {
  firewall_close
  nft add rule inet filter input iifname "$PUBLIC_IFACE" tcp dport { 47989, 47984, 48010 } accept comment "\"$NFT_PUBLIC_COMMENT\""
  nft add rule inet filter input iifname "$PUBLIC_IFACE" udp dport 47998-48010 accept comment "\"$NFT_PUBLIC_COMMENT\""
  echo "Temporary public nftables rules added on $PUBLIC_IFACE"
}

firewall_list() {
  nft -a list chain inet filter input 2>/dev/null | grep -F "$NFT_PUBLIC_COMMENT" || true
}

vpn_firewall_close() {
  firewall_delete_by_comment "$NFT_VPN_COMMENT"
  echo "Temporary VPN/LAN nftables rules removed from inet filter input"
}

vpn_firewall_open() {
  vpn_firewall_close
  nft add rule inet filter input iifname "$WG_IFACE" udp dport 53 accept comment "\"$NFT_VPN_COMMENT\""
  nft add rule inet filter input iifname "$WG_IFACE" tcp dport { 47989, 47984, 48010 } accept comment "\"$NFT_VPN_COMMENT\""
  nft add rule inet filter input iifname "$WG_IFACE" udp dport 47998-48010 accept comment "\"$NFT_VPN_COMMENT\""
  echo "Temporary VPN/LAN nftables rules added on $WG_IFACE"
}

vpn_firewall_list() {
  nft -a list chain inet filter input 2>/dev/null | grep -F "$NFT_VPN_COMMENT" || true
}

check() {
  echo "== config =="
  printf 'MOON_HOST=%s\nLAN_IP=%s\nWG_IFACE=%s\nPUBLIC_IFACE=%s\n' \
    "$MOON_HOST" "$LAN_IP" "$WG_IFACE" "$PUBLIC_IFACE"

  echo
  echo "== interfaces =="
  ip -br addr show "$WG_IFACE" 2>/dev/null || true
  ip -br addr show "$PUBLIC_IFACE" 2>/dev/null || true

  echo
  echo "== Sunshine listeners =="
  ss -lntup 2>/dev/null | grep -E '47989|47984|48010|47998|47999|48000' || true

  echo
  echo "== local DNS test =="
  dig A "$MOON_HOST" @"$LAN_IP" +short || true
  dig AAAA "$MOON_HOST" @"$LAN_IP" +short || true

  echo
  echo "== nftables Moonlight/Sunshine hints =="
  nft list ruleset 2>/dev/null | grep -nE '47989|47984|48010|47998|47999|48000|udp dport 53' || true
  nft list ruleset 2>/dev/null | grep -nF "$WG_IFACE" || true
  nft list ruleset 2>/dev/null | grep -nF "$PUBLIC_IFACE" || true
  nft list ruleset 2>/dev/null | grep -nF "$NFT_COMMENT" || true
}

capture_add() {
  echo "Writing VPN add/pair capture to $ADD_CAPTURE"
  tcpdump -ni any -s0 -A 'tcp port 47989 or tcp port 47984' > "$ADD_CAPTURE"
}

capture_public() {
  echo "Writing public capture to $PUBLIC_CAPTURE"
  tcpdump -ni any -s0 -A \
'tcp port 47989 or tcp port 47984 or tcp port 48010 or udp portrange 47998-48010' \
> "$PUBLIC_CAPTURE"
}

grep_capture() {
  local file="$1"
  grep -nE 'GET|POST|serverinfo|pair|HTTP|Host|plaincert|PairStatus|uniqueid|paired|ClientHello|TLS|47984|48010|'"$MOON_HOST" "$file" || true
}

usage() {
  cat <<EOF
Usage:
  $0 dns-start            Generate dnsmasq config and start split-DNS
  $0 dns-stop             Stop temporary dnsmasq and remove temporary files
  $0 firewall-open        Add temporary public Sunshine/Moonlight rules
  $0 firewall-close       Remove temporary public Sunshine/Moonlight rules
  $0 firewall-list        List temporary public Sunshine/Moonlight rules
  $0 vpn-firewall-open    Add temporary VPN/LAN rules for DNS and Sunshine/Moonlight
  $0 vpn-firewall-close   Remove temporary VPN/LAN rules
  $0 vpn-firewall-list    List temporary VPN/LAN rules
  $0 check                Show config, listeners, DNS test, nft hints
  $0 capture-add          Capture VPN add/pair phase to ADD_CAPTURE
  $0 capture-public       Capture public phase to PUBLIC_CAPTURE
  $0 grep-add             Grep ADD_CAPTURE for useful markers
  $0 grep-public          Grep PUBLIC_CAPTURE for useful markers
  $0 env                  Print resolved environment

Examples:
  sudo $0 dns-start
  sudo $0 vpn-firewall-open
  sudo $0 firewall-open
  sudo $0 firewall-list
  $0 check
  sudo $0 capture-add
  $0 grep-add
EOF
}

cmd="${1:-}"
need_root_for "$cmd"
need_cmds_for "$cmd"

case "$cmd" in
  dns-start) dns_start ;;
  dns-stop) dns_stop ;;
  firewall-open) firewall_open ;;
  firewall-close) firewall_close ;;
  firewall-list) firewall_list ;;
  vpn-firewall-open) vpn_firewall_open ;;
  vpn-firewall-close) vpn_firewall_close ;;
  vpn-firewall-list) vpn_firewall_list ;;
  check) check ;;
  capture-add) capture_add ;;
  capture-public) capture_public ;;
  grep-add) grep_capture "$ADD_CAPTURE" ;;
  grep-public) grep_capture "$PUBLIC_CAPTURE" ;;
  env)
    printf 'ADD_CAPTURE=%s\n' "$ADD_CAPTURE"
    printf 'DNSMASQ_CONF=%s\n' "$DNSMASQ_CONF"
    printf 'DNSMASQ_LOG=%s\n' "$DNSMASQ_LOG"
    printf 'DNSMASQ_PID=%s\n' "$DNSMASQ_PID"
    printf 'LAN_IP=%s\n' "$LAN_IP"
    printf 'MOON_HOST=%s\n' "$MOON_HOST"
    printf 'NFT_COMMENT=%s\n' "$NFT_COMMENT"
    printf 'NFT_PUBLIC_COMMENT=%s\n' "$NFT_PUBLIC_COMMENT"
    printf 'NFT_VPN_COMMENT=%s\n' "$NFT_VPN_COMMENT"
    printf 'PUBLIC_CAPTURE=%s\n' "$PUBLIC_CAPTURE"
    printf 'PUBLIC_IFACE=%s\n' "$PUBLIC_IFACE"
    printf 'UPSTREAM_DNS=%s\n' "$UPSTREAM_DNS"
    printf 'WG_IFACE=%s\n' "$WG_IFACE"
    ;;
  *) usage ;;
esac
