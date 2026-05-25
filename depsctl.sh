#!/usr/bin/env bash
set -euo pipefail

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run '$0 ${1:-install}' as root, e.g. sudo $0 ${1:-install}" >&2
    exit 1
  fi
}

detect_pm() {
  if command -v pacman >/dev/null 2>&1; then
    echo pacman
  elif command -v apt-get >/dev/null 2>&1; then
    echo apt-get
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  elif command -v zypper >/dev/null 2>&1; then
    echo zypper
  elif command -v apk >/dev/null 2>&1; then
    echo apk
  elif command -v opkg >/dev/null 2>&1; then
    echo opkg
  else
    echo unknown
  fi
}

install_runtime() {
  local pm
  pm="$(detect_pm)"

  case "$pm" in
    pacman)
      pacman -S --needed dnsmasq nftables tcpdump bind iproute2
      ;;
    apt-get)
      apt-get update
      apt-get install -y dnsmasq nftables tcpdump dnsutils iproute2
      ;;
    dnf)
      dnf install -y dnsmasq nftables tcpdump bind-utils iproute
      ;;
    yum)
      yum install -y dnsmasq nftables tcpdump bind-utils iproute
      ;;
    zypper)
      zypper install -y dnsmasq nftables tcpdump bind-utils iproute2
      ;;
    apk)
      apk add dnsmasq nftables tcpdump bind-tools iproute2
      ;;
    opkg)
      opkg update
      opkg install dnsmasq nftables tcpdump bind-dig ip-full
      ;;
    *)
      cat >&2 <<EOF
Unsupported package manager. Install these runtime tools manually:
  dnsmasq
  nftables / nft
  tcpdump
  dig
  ss

Package names vary by distribution. Common examples:
  Arch:          sudo pacman -S --needed dnsmasq nftables tcpdump bind iproute2
  Debian/Ubuntu: sudo apt-get install dnsmasq nftables tcpdump dnsutils iproute2
EOF
      exit 1
      ;;
  esac
}

install_shim_runtime() {
  local pm
  pm="$(detect_pm)"

  case "$pm" in
    pacman)
      pacman -S --needed haproxy openssl nftables iproute2 procps-ng sudo gawk grep curl
      ;;
    apt-get)
      apt-get update
      apt-get install -y haproxy openssl nftables iproute2 procps sudo gawk grep curl
      ;;
    dnf)
      dnf install -y haproxy openssl nftables iproute procps-ng sudo gawk grep curl
      ;;
    yum)
      yum install -y haproxy openssl nftables iproute procps-ng sudo gawk grep curl
      ;;
    zypper)
      zypper install -y haproxy openssl nftables iproute2 procps sudo gawk grep curl
      ;;
    apk)
      apk add haproxy openssl nftables iproute2 procps sudo gawk grep curl
      ;;
    opkg)
      opkg update
      opkg install haproxy openssl-util nftables ip-full procps-ng-pkill sudo gawk grep curl
      ;;
    *)
      cat >&2 <<EOF
Unsupported package manager. Install these HTTPS shim tools manually:
  haproxy
  openssl
  nftables / nft
  iproute2 / ss
  procps / pkill
  sudo
  awk
  grep
  curl

systemd/systemctl is also required by the shim installer.

Package names vary by distribution. Common examples:
  Arch:          sudo pacman -S --needed haproxy openssl nftables iproute2 procps-ng sudo gawk grep curl
  Debian/Ubuntu: sudo apt-get install haproxy openssl nftables iproute2 procps sudo gawk grep curl
EOF
      exit 1
      ;;
  esac
}

check_commands() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf 'ok: %s\n' "$cmd"
    else
      printf 'missing: %s\n' "$cmd"
      missing=1
    fi
  done
  return "$missing"
}

check_runtime() {
  check_commands dnsmasq nft tcpdump dig ss ip grep pkill
}

check_shim_runtime() {
  check_commands sudo awk openssl haproxy nft systemctl ss pkill grep curl
}

check_all_runtime() {
  local missing=0

  echo "== split-DNS/plain tools =="
  check_runtime || missing=1

  echo
  echo "== hostname HTTPS shim tools =="
  check_shim_runtime || missing=1

  return "$missing"
}

usage() {
  cat <<EOF
Usage:
  $0 install        Install split-DNS/plain runtime tools for moonctl.sh
  $0 install-shim   Install hostname HTTPS shim runtime tools
  $0 install-all    Install both runtime tool sets
  $0 check          Check split-DNS/plain runtime tools
  $0 check-shim     Check hostname HTTPS shim runtime tools
  $0 check-all      Check both runtime tool sets

Split-DNS/plain runtime tools:
  dnsmasq
  nftables / nft
  tcpdump
  dig
  ss
  ip
  grep
  pkill

Hostname HTTPS shim runtime tools:
  sudo
  awk
  openssl
  haproxy
  nftables / nft
  systemd / systemctl
  ss
  pkill
  grep
  curl

Examples:
  sudo $0 install
  sudo $0 install-shim
  sudo $0 install-all
  $0 check
  $0 check-shim
EOF
}

cmd="${1:-}"

case "$cmd" in
  install)
    need_root "$cmd"
    install_runtime
    ;;
  install-shim)
    need_root "$cmd"
    install_shim_runtime
    ;;
  install-all)
    need_root "$cmd"
    install_runtime
    install_shim_runtime
    ;;
  check)
    check_runtime
    ;;
  check-shim)
    check_shim_runtime
    ;;
  check-all)
    check_all_runtime
    ;;
  *)
    usage
    ;;
esac
