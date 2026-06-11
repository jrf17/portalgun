#!/usr/bin/env bash
set -e
user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER}}}"
home=$(getent passwd "$user" | cut -d: -f6)
run_as() { if [ "$(id -u)" -eq 0 ] && [ "$user" != root ]; then sudo -H -u "$user" env HOME="$home" USER="$user" LOGNAME="$user" "$@"; else env HOME="$home" USER="$user" LOGNAME="$user" "$@"; fi; }
case "${1:-}" in
  install)
    command -v tmux >/dev/null 2>&1 || { [ "$(id -u)" -eq 0 ] && apt-get install -y tmux || sudo apt-get install -y tmux; }
    run_as mkdir -p "$home/.tmux/plugins"
    [ -d "$home/.tmux/plugins/tpm" ] || run_as git clone -q https://github.com/tmux-plugins/tpm "$home/.tmux/plugins/tpm"
    ;;
  verify) command -v tmux >/dev/null 2>&1 ;;
  describe) echo 'Tmux terminal multiplexer' ;;
  *) exit 64 ;;
esac
