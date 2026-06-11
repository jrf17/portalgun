#!/usr/bin/env bash
set -euo pipefail
user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER}}}"
home=$(getent passwd "$user" | cut -d: -f6)
run_as() { if [ "$(id -u)" -eq 0 ] && [ "$user" != root ]; then sudo -H -u "$user" env HOME="$home" USER="$user" LOGNAME="$user" "$@"; else env HOME="$home" USER="$user" LOGNAME="$user" "$@"; fi; }
case "${1:-}" in
  install)
    if [ ! -d "$home/.oh-my-bash" ]; then
      tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh -o "$tmp"
      run_as bash "$tmp" --unattended
      rm -f "$tmp"
    fi
    ;;
  verify) [ -d "$home/.oh-my-bash" ] ;;
  describe) echo 'Oh My Bash' ;;
  *) exit 64 ;;
esac
