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

need_root_for() {
  case "${1:-}" in
    dns-start|dns-stop|firewall-open|capture-add|capture-public)
      if [[ "${EUID}" -ne 0 ]]; then
        echo "Please run '$0 $1' as root, e.g. sudo $0 $1" >&2
        exit 1
      fi
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

dns_start() {
  write_dnsmasq_conf

  if [[ -f "$DNSMASQ_PID" ]]; then
    kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
  fi

  pkill -f "$DNSMASQ_CONF" 2>/dev/null || true

  dnsmasq \
    --conf-file="$DNSMASQ_CONF" \
    --pid-file="$DNSMASQ_PID"

  echo "dnsmasq started:"
  echo "  $MOON_HOST -> $LAN_IP"
  echo "  conf: $DNSMASQ_CONF"
  echo "  log:  $DNSMASQ_LOG"
}

dns_stop() {
  if [[ -f "$DNSMASQ_PID" ]]; then
    kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
    rm -f "$DNSMASQ_PID"
  fi
  pkill -f "$DNSMASQ_CONF" 2>/dev/null || true
  echo "dnsmasq stopped"
}

firewall_open() {
  nft add rule inet filter input iifname "$PUBLIC_IFACE" tcp dport { 47989, 47984, 48010 } accept
  nft add rule inet filter input iifname "$PUBLIC_IFACE" udp dport 47998-48010 accept
  echo "Temporary nftables rules added on $PUBLIC_IFACE"
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
  nft list ruleset 2>/dev/null | grep -nE '47989|47984|48010|47998|48010|'"$PUBLIC_IFACE" || true
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
  $0 dns-start        Generate dnsmasq config and start split-DNS
  $0 dns-stop         Stop temporary dnsmasq
  $0 firewall-open    Add temporary nftables rules for Sunshine/Moonlight
  $0 check            Show config, listeners, DNS test, nft hints
  $0 capture-add      Capture VPN add/pair phase to ADD_CAPTURE
  $0 capture-public   Capture public phase to PUBLIC_CAPTURE
  $0 grep-add         Grep ADD_CAPTURE for useful markers
  $0 grep-public      Grep PUBLIC_CAPTURE for useful markers
  $0 env              Print resolved environment

Examples:
  sudo $0 dns-start
  sudo $0 firewall-open
  $0 check
  sudo $0 capture-add
  $0 grep-add
EOF
}

cmd="${1:-}"
need_root_for "$cmd"

case "$cmd" in
  dns-start) dns_start ;;
  dns-stop) dns_stop ;;
  firewall-open) firewall_open ;;
  check) check ;;
  capture-add) capture_add ;;
  capture-public) capture_public ;;
  grep-add) grep_capture "$ADD_CAPTURE" ;;
  grep-public) grep_capture "$PUBLIC_CAPTURE" ;;
  env)
    env | grep -E '^(MOON_HOST|LAN_IP|WG_IFACE|PUBLIC_IFACE|UPSTREAM_DNS|DNSMASQ_|ADD_CAPTURE|PUBLIC_CAPTURE)=' | sort
    ;;
  *) usage ;;
esac
