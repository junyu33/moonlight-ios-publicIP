#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${SUNSHINE_CREDENTIALS_DIR:=$HOME/.config/sunshine/credentials}"
: "${SUNSHINE_RESTART_CMD:=systemctl --user restart sunshine}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as your normal user. It will call sudo when needed." >&2
  exit 1
fi

RESTORE_BAK="${1:-}"

echo "== Stop services =="
sudo systemctl disable --now moonlight-https-shim-nft.service 2>/dev/null || true
sudo systemctl disable --now moonlight-47989-haproxy.service 2>/dev/null || true

echo
echo "== Remove runtime rules/processes =="
sudo /usr/local/sbin/moonlight-https-shim-nft down 2>/dev/null || true
sudo pkill haproxy 2>/dev/null || true

echo
echo "== Remove installed files =="
sudo rm -f /etc/systemd/system/moonlight-https-shim-nft.service
sudo rm -f /etc/systemd/system/moonlight-47989-haproxy.service
sudo rm -f /usr/local/sbin/moonlight-https-shim-nft
sudo rm -f /etc/haproxy/moonlight-47989-only-le.cfg
sudo systemctl daemon-reload

if [[ -n "$RESTORE_BAK" ]]; then
  echo
  echo "== Restore Sunshine credentials from $RESTORE_BAK =="
  sudo test -f "$RESTORE_BAK/cacert.pem"
  sudo test -f "$RESTORE_BAK/cakey.pem"

  sudo cp "$RESTORE_BAK/cacert.pem" "$SUNSHINE_CREDENTIALS_DIR/cacert.pem"
  sudo cp "$RESTORE_BAK/cakey.pem"  "$SUNSHINE_CREDENTIALS_DIR/cakey.pem"
  sudo chmod 644 "$SUNSHINE_CREDENTIALS_DIR/cacert.pem"
  sudo chmod 600 "$SUNSHINE_CREDENTIALS_DIR/cakey.pem"

  echo "Restarting Sunshine with: $SUNSHINE_RESTART_CMD"
  eval "$SUNSHINE_RESTART_CMD"
else
  echo
  echo "No Sunshine credential backup path supplied; leaving current Sunshine cert/key unchanged."
  echo "To restore original cert/key:"
  echo "  $0 /home/<user>/.config/sunshine/credentials.bak.YYYYMMDD-HHMMSS"
fi

echo
echo "Uninstalled HTTPS shim."
