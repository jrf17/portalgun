#!/usr/bin/env bash
set -euo pipefail
install_ghostty() {
  command -v ghostty >/dev/null 2>&1 && return 0
  if apt-cache show ghostty >/dev/null 2>&1; then
    [ "$(id -u)" -eq 0 ] && apt-get install -y ghostty || sudo apt-get install -y ghostty
    command -v ghostty >/dev/null 2>&1
    return
  fi
  local arch release_json target url tmp
  arch=$(dpkg --print-architecture)
  case "$arch" in amd64|arm64) ;; *) echo "Unsupported Ghostty architecture: $arch" >&2; return 2;; esac
  release_json=$(curl -fsSL https://api.github.com/repos/mkasberg/ghostty-ubuntu/releases/latest)
  for target in forky trixie; do
    url=$(jq -r --arg suffix "_${arch}_${target}.deb" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' <<<"$release_json" | head -1)
    [ -n "$url" ] && [ "$url" != null ] && break
  done
  [ -n "${url:-}" ] && [ "$url" != null ] || { echo 'No compatible Ghostty Debian package found' >&2; return 1; }
  tmp=$(mktemp --suffix=.deb)
  curl -fsSL "$url" -o "$tmp"
  if [ "$(id -u)" -eq 0 ]; then
    apt-get -s install "$tmp" >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp"
  else
    sudo apt-get -s install "$tmp" >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp"
  fi
  rm -f "$tmp"
  command -v ghostty >/dev/null 2>&1
}
case "${1:-}" in
  install) install_ghostty ;;
  verify) command -v ghostty >/dev/null 2>&1 ;;
  describe) echo 'Ghostty terminal emulator' ;;
  *) exit 64 ;;
esac
