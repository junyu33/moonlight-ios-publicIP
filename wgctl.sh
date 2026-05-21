#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${LAN_IP:?Set LAN_IP in .env}"
: "${WG_IFACE:=moonwg0}"
: "${PUBLIC_IFACE:=enp3s0}"
: "${WG_PORT:=51820}"
: "${WG_SERVER_ADDR:=$LAN_IP/24}"
: "${WG_CLIENT_NAME:=iphone}"
: "${WG_CLIENT_ADDR:=10.0.42.2/32}"
: "${WG_DNS:=$LAN_IP}"
: "${WG_ALLOWED_IPS:=10.0.42.0/24}"
: "${WG_STATE_DIR:=/etc/wireguard/$WG_IFACE.d}"
: "${WG_SERVER_CONF:=/etc/wireguard/$WG_IFACE.conf}"
: "${WG_CLIENT_CONF:=/tmp/$WG_IFACE-$WG_CLIENT_NAME.conf}"

need_root_for() {
  case "${1:-}" in
    install|gen-keys|write-server|write-client|firewall-open|show-client|qr-client|up|down|restart|status)
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

install_packages() {
  if command -v pacman >/dev/null 2>&1; then
    pacman -S --needed wireguard-tools qrencode
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y wireguard-tools qrencode
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools qrencode
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y wireguard-tools qrencode
  elif command -v apk >/dev/null 2>&1; then
    apk add wireguard-tools qrencode
  else
    echo "Unsupported package manager. Install wireguard-tools and qrencode manually." >&2
    exit 1
  fi
}

key_path() {
  local name="$1"
  printf '%s/%s' "$WG_STATE_DIR" "$name"
}

gen_keys() {
  need_cmd wg

  install -d -m 700 "$WG_STATE_DIR"
  umask 077

  if [[ ! -f "$(key_path server.key)" ]]; then
    wg genkey | tee "$(key_path server.key)" | wg pubkey > "$(key_path server.pub)"
  fi

  if [[ ! -f "$(key_path "$WG_CLIENT_NAME.key")" ]]; then
    wg genkey | tee "$(key_path "$WG_CLIENT_NAME.key")" | wg pubkey > "$(key_path "$WG_CLIENT_NAME.pub")"
  fi

  echo "WireGuard keys are ready in $WG_STATE_DIR"
  echo "Keep this directory private."
}

require_keys() {
  local missing=0
  for file in server.key server.pub "$WG_CLIENT_NAME.key" "$WG_CLIENT_NAME.pub"; do
    if [[ ! -f "$(key_path "$file")" ]]; then
      echo "Missing $(key_path "$file")" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "Run: sudo $0 gen-keys" >&2
    exit 1
  fi
}

write_server() {
  require_keys

  if [[ -f "$WG_SERVER_CONF" && "${FORCE:-0}" != "1" ]]; then
    echo "$WG_SERVER_CONF already exists. Set FORCE=1 to overwrite." >&2
    exit 1
  fi

  install -d -m 700 "$(dirname "$WG_SERVER_CONF")"
  umask 077

  cat > "$WG_SERVER_CONF" <<EOF
[Interface]
PrivateKey = $(<"$(key_path server.key)")
Address = $WG_SERVER_ADDR
ListenPort = $WG_PORT

[Peer]
# $WG_CLIENT_NAME
PublicKey = $(<"$(key_path "$WG_CLIENT_NAME.pub")")
AllowedIPs = $WG_CLIENT_ADDR
EOF

  chmod 600 "$WG_SERVER_CONF"
  echo "Wrote $WG_SERVER_CONF"
  echo "Make sure UDP $WG_PORT is allowed on your public interface."
}

write_client() {
  require_keys

  if [[ -z "${WG_ENDPOINT:-}" ]]; then
    echo "Set WG_ENDPOINT, for example:" >&2
    echo "  sudo env WG_ENDPOINT=moon.example.test:$WG_PORT $0 write-client" >&2
    exit 1
  fi

  if [[ -f "$WG_CLIENT_CONF" && "${FORCE:-0}" != "1" ]]; then
    echo "$WG_CLIENT_CONF already exists. Set FORCE=1 to overwrite." >&2
    exit 1
  fi

  umask 077

  cat > "$WG_CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $(<"$(key_path "$WG_CLIENT_NAME.key")")
Address = $WG_CLIENT_ADDR
DNS = $WG_DNS

[Peer]
PublicKey = $(<"$(key_path server.pub)")
Endpoint = $WG_ENDPOINT
AllowedIPs = $WG_ALLOWED_IPS
PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CLIENT_CONF"
  echo "Wrote $WG_CLIENT_CONF"
}

firewall_open() {
  need_cmd nft
  nft add rule inet filter input iifname "$PUBLIC_IFACE" udp dport "$WG_PORT" accept
  echo "Temporary nftables rule added on $PUBLIC_IFACE for UDP $WG_PORT"
}

up() {
  need_cmd wg-quick
  wg-quick up "$WG_IFACE"
}

down() {
  need_cmd wg-quick
  wg-quick down "$WG_IFACE"
}

restart() {
  need_cmd wg-quick
  wg-quick down "$WG_IFACE" 2>/dev/null || true
  wg-quick up "$WG_IFACE"
}

status() {
  echo "== config =="
  printf 'WG_IFACE=%s\nWG_PORT=%s\nWG_SERVER_ADDR=%s\nWG_CLIENT_NAME=%s\nWG_CLIENT_ADDR=%s\nWG_DNS=%s\n' \
    "$WG_IFACE" "$WG_PORT" "$WG_SERVER_ADDR" "$WG_CLIENT_NAME" "$WG_CLIENT_ADDR" "$WG_DNS"
  printf 'PUBLIC_IFACE=%s\nWG_ALLOWED_IPS=%s\n' "$PUBLIC_IFACE" "$WG_ALLOWED_IPS"
  printf 'WG_STATE_DIR=%s\nWG_SERVER_CONF=%s\nWG_CLIENT_CONF=%s\n' \
    "$WG_STATE_DIR" "$WG_SERVER_CONF" "$WG_CLIENT_CONF"

  echo
  echo "== interface =="
  ip -br addr show "$WG_IFACE" 2>/dev/null || true

  echo
  echo "== wg =="
  wg show "$WG_IFACE"
}

show_client() {
  if [[ ! -f "$WG_CLIENT_CONF" ]]; then
    echo "Missing $WG_CLIENT_CONF. Run: WG_ENDPOINT=<host:port> $0 write-client" >&2
    exit 1
  fi
  cat "$WG_CLIENT_CONF"
}

qr_client() {
  need_cmd qrencode
  if [[ ! -f "$WG_CLIENT_CONF" ]]; then
    echo "Missing $WG_CLIENT_CONF. Run: WG_ENDPOINT=<host:port> $0 write-client" >&2
    exit 1
  fi
  qrencode -t ansiutf8 < "$WG_CLIENT_CONF"
}

sysctl_hints() {
  cat <<EOF
For routed VPN traffic, enable IPv4 forwarding on the Sunshine host:

  sudo sysctl -w net.ipv4.ip_forward=1

To persist it, create a sysctl file outside this repository, for example:

  /etc/sysctl.d/99-$WG_IFACE.conf

with:

  net.ipv4.ip_forward=1

This script does not add NAT automatically. Add only the routing or NAT rules
your network actually needs.
EOF
}

usage() {
  cat <<EOF
Usage:
  $0 install        Install wireguard-tools and qrencode
  $0 gen-keys       Generate server and client keys under WG_STATE_DIR
  $0 write-server   Write WG_SERVER_CONF
  $0 write-client   Write WG_CLIENT_CONF; requires WG_ENDPOINT=host:port
  $0 firewall-open  Add temporary nftables rule for the WireGuard UDP port
  $0 up             Start wg-quick for WG_IFACE
  $0 down           Stop wg-quick for WG_IFACE
  $0 restart        Restart wg-quick for WG_IFACE
  $0 status         Show WireGuard interface and peer state
  $0 show-client    Print generated client config
  $0 qr-client      Print generated client config as QR code
  $0 sysctl-hints   Print IPv4 forwarding notes
  $0 env            Print resolved WireGuard environment

Examples:
  sudo $0 install
  sudo $0 gen-keys
  sudo $0 write-server
  sudo $0 firewall-open
  sudo env WG_ENDPOINT=moon.example.test:51820 $0 write-client
  sudo $0 up
  sudo $0 status
  sudo $0 qr-client

Set FORCE=1 to overwrite generated config files.
EOF
}

cmd="${1:-}"
need_root_for "$cmd"

case "$cmd" in
  install) install_packages ;;
  gen-keys) gen_keys ;;
  write-server) write_server ;;
  write-client) write_client ;;
  firewall-open) firewall_open ;;
  up) up ;;
  down) down ;;
  restart) restart ;;
  status) status ;;
  show-client) show_client ;;
  qr-client) qr_client ;;
  sysctl-hints) sysctl_hints ;;
  env)
    printf 'LAN_IP=%s\n' "$LAN_IP"
    printf 'PUBLIC_IFACE=%s\n' "$PUBLIC_IFACE"
    printf 'WG_ALLOWED_IPS=%s\n' "$WG_ALLOWED_IPS"
    printf 'WG_CLIENT_ADDR=%s\n' "$WG_CLIENT_ADDR"
    printf 'WG_CLIENT_CONF=%s\n' "$WG_CLIENT_CONF"
    printf 'WG_CLIENT_NAME=%s\n' "$WG_CLIENT_NAME"
    printf 'WG_DNS=%s\n' "$WG_DNS"
    printf 'WG_IFACE=%s\n' "$WG_IFACE"
    printf 'WG_PORT=%s\n' "$WG_PORT"
    printf 'WG_SERVER_ADDR=%s\n' "$WG_SERVER_ADDR"
    printf 'WG_SERVER_CONF=%s\n' "$WG_SERVER_CONF"
    printf 'WG_STATE_DIR=%s\n' "$WG_STATE_DIR"
    if [[ -n "${WG_ENDPOINT:-}" ]]; then
      printf 'WG_ENDPOINT=%s\n' "$WG_ENDPOINT"
    fi
    ;;
  *) usage ;;
esac
