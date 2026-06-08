#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  install)
    if ! command -v zellij >/dev/null 2>&1; then
      arch=$(uname -m)
      case "$arch" in x86_64) asset='zellij-x86_64-unknown-linux-musl.tar.gz';; aarch64) asset='zellij-aarch64-unknown-linux-musl.tar.gz';; *) echo "Unsupported Zellij architecture: $arch" >&2; exit 2;; esac
      url=$(curl -fsSL https://api.github.com/repos/zellij-org/zellij/releases/latest | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' | head -1)
      [ -n "$url" ] || { echo 'Zellij release asset not found' >&2; exit 1; }
      tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
      curl -fsSL "$url" -o "$tmp/zellij.tgz"
      tar xzf "$tmp/zellij.tgz" -C "$tmp"
      [ "$(id -u)" -eq 0 ] && install -m 0755 "$tmp/zellij" /usr/local/bin/zellij || sudo install -m 0755 "$tmp/zellij" /usr/local/bin/zellij
    fi
    ;;
  verify) command -v zellij >/dev/null 2>&1 ;;
  describe) echo 'Zellij terminal multiplexer' ;;
  *) exit 64 ;;
esac
