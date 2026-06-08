#!/usr/bin/env bash
set -e
provider='zsh'
user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER}}}"
case "${1:-}" in
  install)
    command -v "$provider" >/dev/null 2>&1 || { [ "$(id -u)" -eq 0 ] && apt-get install -y "$provider" || sudo apt-get install -y "$provider"; }
    if [ "$(jq -r '.shell.set_as_default // false' "$PORTALGUN_PROFILE_FILE")" = true ]; then
      path="$(command -v "$provider")"
      current="$(getent passwd "$user" | cut -d: -f7)"
      [ "$current" = "$path" ] || { [ "$(id -u)" -eq 0 ] && chsh -s "$path" "$user" || sudo chsh -s "$path" "$user"; }
    fi
    ;;
  verify)
    command -v "$provider" >/dev/null 2>&1 || exit 1
    if [ "$(jq -r '.shell.set_as_default // false' "$PORTALGUN_PROFILE_FILE")" = true ]; then
      [ "$(getent passwd "$user" | cut -d: -f7)" = "$(command -v "$provider")" ]
    fi
    ;;
  describe) echo 'zsh command-line interpreter' ;;
  *) exit 64 ;;
esac
