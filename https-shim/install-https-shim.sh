#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as your normal user. It will call sudo when needed." >&2
  exit 1
fi

: "${MOON_HOST:?Set MOON_HOST in .env, e.g. moon.example.test}"
: "${LAN_IP:?Set LAN_IP in .env, e.g. 10.0.42.1}"
: "${PUBLIC_IFACE:?Set PUBLIC_IFACE in .env, e.g. enp3s0}"

: "${HAPROXY_TLS_PORT:=48489}"
: "${SUNSHINE_HTTP_PORT:=47989}"
: "${SUNSHINE_HTTPS_PORT:=47984}"
: "${SUNSHINE_RTSP_PORT:=48010}"
: "${SUNSHINE_UDP_RANGE:=47998-48010}"
: "${LE_COMBINED_PEM:=/etc/haproxy/certs/moon.example.test.pem}"
: "${SUNSHINE_CREDENTIALS_DIR:=$HOME/.config/sunshine/credentials}"
: "${SUNSHINE_RESTART_CMD:=systemctl --user restart sunshine}"
: "${NFT_COMMENT_PREFIX:=moonlight-ios-publicIP:https-shim}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

for cmd in sudo awk openssl haproxy nft systemctl ss; do
  need_cmd "$cmd"
done

if ! sudo test -f "$LE_COMBINED_PEM"; then
  echo "Missing LE combined PEM: $LE_COMBINED_PEM" >&2
  echo "It must contain certificate/fullchain followed by the private key." >&2
  exit 1
fi

if ! sudo test -f "$SUNSHINE_CREDENTIALS_DIR/cacert.pem" || ! sudo test -f "$SUNSHINE_CREDENTIALS_DIR/cakey.pem"; then
  echo "Missing Sunshine credentials in: $SUNSHINE_CREDENTIALS_DIR" >&2
  exit 1
fi

if ! sudo nft list chain inet filter input >/dev/null 2>&1; then
  echo "Missing nft chain: inet filter input" >&2
  echo "Create your base firewall first, or adapt the nft helper script." >&2
  exit 1
fi

echo "== Backup Sunshine credentials =="
BAK="$(dirname "$SUNSHINE_CREDENTIALS_DIR")/credentials.bak.$(date +%Y%m%d-%H%M%S)"
sudo install -d -m 700 "$BAK"
sudo cp -a "$SUNSHINE_CREDENTIALS_DIR/cacert.pem" "$BAK/cacert.pem"
sudo cp -a "$SUNSHINE_CREDENTIALS_DIR/cakey.pem"  "$BAK/cakey.pem"
echo "Backup: $BAK"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo
echo "== Extract public cert/key from LE combined PEM =="
sudo awk '
  /BEGIN CERTIFICATE/ {p=1}
  p {print}
  /END CERTIFICATE/ {exit}
' "$LE_COMBINED_PEM" > "$TMPDIR/le-cert.pem"

sudo awk '
  /BEGIN .*PRIVATE KEY/ {p=1}
  p {print}
' "$LE_COMBINED_PEM" > "$TMPDIR/le-key.pem"

openssl x509 -in "$TMPDIR/le-cert.pem" -noout -subject -issuer -dates
openssl pkey -in "$TMPDIR/le-key.pem" -check -noout >/dev/null

echo
echo "== Install public cert/key into Sunshine credentials =="
sudo cp "$TMPDIR/le-cert.pem" "$SUNSHINE_CREDENTIALS_DIR/cacert.pem"
sudo cp "$TMPDIR/le-key.pem"  "$SUNSHINE_CREDENTIALS_DIR/cakey.pem"
sudo chmod 644 "$SUNSHINE_CREDENTIALS_DIR/cacert.pem"
sudo chmod 600 "$SUNSHINE_CREDENTIALS_DIR/cakey.pem"

echo "Restarting Sunshine with: $SUNSHINE_RESTART_CMD"
eval "$SUNSHINE_RESTART_CMD"

sleep 1

echo
echo "== Verify Sunshine HTTPS/mTLS endpoint presents public cert =="
CERT_DUMP="$TMPDIR/sunshine-47984-cert.pem"

set +o pipefail
openssl s_client -connect "127.0.0.1:$SUNSHINE_HTTPS_PORT" -servername "$MOON_HOST" </dev/null 2>/dev/null \
  | openssl x509 -out "$CERT_DUMP" >/dev/null
CERT_EXTRACT_STATUS=$?
set -o pipefail

if [[ "$CERT_EXTRACT_STATUS" -ne 0 ]]; then
  echo "Failed to extract Sunshine 47984 server certificate." >&2
  exit 1
fi

openssl x509 -in "$CERT_DUMP" -noout -subject -issuer -fingerprint -sha256

echo
echo "== Install HAProxy config =="
sudo install -d -m 755 /etc/haproxy

sudo tee /etc/haproxy/moonlight-47989-only-le.cfg >/dev/null <<CFG
global
    maxconn 256
    log stdout format raw local0

defaults
    log global
    mode http
    option httplog
    timeout connect 5s
    timeout client 60s
    timeout server 60s

frontend moonlight_tls_${HAPROXY_TLS_PORT}_le
    bind 0.0.0.0:${HAPROXY_TLS_PORT} ssl crt ${LE_COMBINED_PEM} alpn http/1.1
    default_backend sunshine_http_${SUNSHINE_HTTP_PORT}

backend sunshine_http_${SUNSHINE_HTTP_PORT}
    server sunshine_http 127.0.0.1:${SUNSHINE_HTTP_PORT}
CFG

sudo haproxy -c -f /etc/haproxy/moonlight-47989-only-le.cfg

echo
echo "== Install HAProxy systemd service =="
sudo tee /etc/systemd/system/moonlight-47989-haproxy.service >/dev/null <<'SERVICE'
[Unit]
Description=Moonlight hostname HTTPS shim for Sunshine 47989
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/haproxy -f /etc/haproxy/moonlight-47989-only-le.cfg -db
ExecReload=/bin/kill -USR2 $MAINPID
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
SERVICE

echo
echo "== Install nft helper =="
sudo tee /usr/local/sbin/moonlight-https-shim-nft >/dev/null <<NFTHELPER
#!/usr/bin/env bash
set -euo pipefail

PUBLIC_IFACE="${PUBLIC_IFACE}"
HAPROXY_TLS_PORT="${HAPROXY_TLS_PORT}"
SUNSHINE_HTTPS_PORT="${SUNSHINE_HTTPS_PORT}"
SUNSHINE_RTSP_PORT="${SUNSHINE_RTSP_PORT}"
SUNSHINE_UDP_RANGE_START="${SUNSHINE_UDP_RANGE%-*}"
SUNSHINE_UDP_RANGE_END="${SUNSHINE_UDP_RANGE#*-}"
NFT_COMMENT_PREFIX="${NFT_COMMENT_PREFIX}"

delete_filter_rules() {
  local handle
  while IFS= read -r handle; do
    [[ -n "\$handle" ]] && nft delete rule inet filter input handle "\$handle" 2>/dev/null || true
  done < <(nft -a list chain inet filter input 2>/dev/null | awk -v p="\$NFT_COMMENT_PREFIX" '\$0 ~ p {print \$NF}')
}

down() {
  nft delete table ip moonlight_https_nat 2>/dev/null || true
  delete_filter_rules
}

up() {
  down

  nft add table ip moonlight_https_nat
  nft 'add chain ip moonlight_https_nat prerouting { type nat hook prerouting priority dstnat; policy accept; }'

  nft add rule ip moonlight_https_nat prerouting \
    iifname "\$PUBLIC_IFACE" tcp dport 47989 \
    redirect to :"\$HAPROXY_TLS_PORT" \
    comment "\"\$NFT_COMMENT_PREFIX:tls-47989-public\""

  nft add rule inet filter input \
    iifname "\$PUBLIC_IFACE" tcp dport "\$HAPROXY_TLS_PORT" \
    accept comment "\"\$NFT_COMMENT_PREFIX:public-haproxy\""

  nft add rule inet filter input \
    iifname "\$PUBLIC_IFACE" tcp dport "\$SUNSHINE_HTTPS_PORT" \
    accept comment "\"\$NFT_COMMENT_PREFIX:public-https\""

  nft add rule inet filter input \
    iifname "\$PUBLIC_IFACE" tcp dport "\$SUNSHINE_RTSP_PORT" \
    accept comment "\"\$NFT_COMMENT_PREFIX:public-rtsp\""

  nft add rule inet filter input \
    iifname "\$PUBLIC_IFACE" udp dport "\$SUNSHINE_UDP_RANGE_START"-"\$SUNSHINE_UDP_RANGE_END" \
    accept comment "\"\$NFT_COMMENT_PREFIX:public-udp\""
}

check_line() {
  local name="\$1"
  local haystack="\$2"
  local comment="\$3"
  shift 3

  local line
  line="\$(printf '%s\n' "\$haystack" | grep -F "comment \"\$comment\"" || true)"
  if [[ -z "\$line" ]]; then
    echo "missing: \$name (\$comment)" >&2
    return 1
  fi

  local token
  for token in "\$@"; do
    if [[ "\$line" != *"\$token"* ]]; then
      echo "invalid: \$name missing token: \$token" >&2
      echo "line: \$line" >&2
      return 1
    fi
  done

  echo "ok: \$name"
}

status() {
  local missing=0
  local nat_rules filter_rules

  nat_rules="\$(nft -a list table ip moonlight_https_nat 2>/dev/null || true)"
  if [[ -z "\$nat_rules" ]]; then
    echo "missing: table ip moonlight_https_nat" >&2
    missing=1
  else
    echo "ok: table ip moonlight_https_nat"
  fi

  filter_rules="\$(nft -a list chain inet filter input 2>/dev/null || true)"

  check_line "public 47989 redirect" "\$nat_rules" "\$NFT_COMMENT_PREFIX:tls-47989-public" \
    "iifname \"\$PUBLIC_IFACE\"" "tcp dport 47989" "redirect to :\$HAPROXY_TLS_PORT" || missing=1

  check_line "public haproxy accept" "\$filter_rules" "\$NFT_COMMENT_PREFIX:public-haproxy" \
    "iifname \"\$PUBLIC_IFACE\"" "tcp dport \$HAPROXY_TLS_PORT" "accept" || missing=1

  check_line "public https accept" "\$filter_rules" "\$NFT_COMMENT_PREFIX:public-https" \
    "iifname \"\$PUBLIC_IFACE\"" "tcp dport \$SUNSHINE_HTTPS_PORT" "accept" || missing=1

  check_line "public rtsp accept" "\$filter_rules" "\$NFT_COMMENT_PREFIX:public-rtsp" \
    "iifname \"\$PUBLIC_IFACE\"" "tcp dport \$SUNSHINE_RTSP_PORT" "accept" || missing=1

  check_line "public udp accept" "\$filter_rules" "\$NFT_COMMENT_PREFIX:public-udp" \
    "iifname \"\$PUBLIC_IFACE\"" "udp dport \$SUNSHINE_UDP_RANGE_START-\$SUNSHINE_UDP_RANGE_END" "accept" || missing=1

  return "\$missing"
}

case "\${1:-up}" in
  up) up ;;
  down) down ;;
  list)
    nft -a list table ip moonlight_https_nat 2>/dev/null || true
    nft -a list chain inet filter input 2>/dev/null | grep -F "\$NFT_COMMENT_PREFIX" || true
    ;;
  status) status ;;
  *)
    echo "Usage: \$0 {up|down|list|status}" >&2
    exit 2
    ;;
esac
NFTHELPER

sudo chmod 755 /usr/local/sbin/moonlight-https-shim-nft

echo
echo "== Install nft systemd service =="
sudo tee /etc/systemd/system/moonlight-https-shim-nft.service >/dev/null <<'SERVICE'
[Unit]
Description=Moonlight hostname HTTPS shim nftables rules
After=network-online.target moonlight-47989-haproxy.service
Wants=network-online.target
Requires=moonlight-47989-haproxy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/moonlight-https-shim-nft up
ExecStop=/usr/local/sbin/moonlight-https-shim-nft down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

echo
echo "== Enable services =="
sudo systemctl daemon-reload
sudo systemctl enable --now moonlight-47989-haproxy.service
sudo systemctl enable --now moonlight-https-shim-nft.service

echo
echo "== Status =="
sudo systemctl --no-pager --full status moonlight-47989-haproxy.service || true
sudo /usr/local/sbin/moonlight-https-shim-nft list
sudo /usr/local/sbin/moonlight-https-shim-nft status
sudo ss -lntp | grep -E "47984|47989|48489" || true

echo
echo "Installed successfully."
echo "Sunshine credential backup: $BAK"
echo
echo "Validation:"
echo "  curl -vk --noproxy '*' --resolve $MOON_HOST:$HAPROXY_TLS_PORT:$LAN_IP https://$MOON_HOST:$HAPROXY_TLS_PORT/serverinfo"
echo "  openssl s_client -connect 127.0.0.1:$SUNSHINE_HTTPS_PORT -servername $MOON_HOST </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -fingerprint -sha256"
