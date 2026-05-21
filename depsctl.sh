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

check_runtime() {
  local missing=0
  local cmd
  for cmd in dnsmasq nft tcpdump dig ss; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf 'ok: %s\n' "$cmd"
    else
      printf 'missing: %s\n' "$cmd"
      missing=1
    fi
  done
  return "$missing"
}

usage() {
  cat <<EOF
Usage:
  $0 install   Install runtime tools for moonctl.sh
  $0 check     Check runtime tools are available

Runtime tools:
  dnsmasq
  nftables / nft
  tcpdump
  dig
  ss

Examples:
  sudo $0 install
  $0 check
EOF
}

cmd="${1:-}"

case "$cmd" in
  install)
    need_root "$cmd"
    install_runtime
    ;;
  check)
    check_runtime
    ;;
  *)
    usage
    ;;
esac
