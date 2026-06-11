#!/usr/bin/env bash
set -euo pipefail
user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER}}}"
home=$(getent passwd "$user" | cut -d: -f6)
run_as() { if [ "$(id -u)" -eq 0 ] && [ "$user" != root ]; then sudo -H -u "$user" env HOME="$home" USER="$user" LOGNAME="$user" "$@"; else env HOME="$home" USER="$user" LOGNAME="$user" "$@"; fi; }
case "${1:-}" in
  install)
    if [ ! -f "$home/.config/fish/functions/fisher.fish" ]; then
      run_as fish -c 'curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source; fisher install jorgebucaran/fisher'
    fi
    ;;
  verify) [ -f "$home/.config/fish/functions/fisher.fish" ] ;;
  describe) echo 'Fisher plugin manager' ;;
  *) exit 64 ;;
esac
