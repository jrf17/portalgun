#!/usr/bin/env bash
set -euo pipefail
user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER}}}"
home=$(getent passwd "$user" | cut -d: -f6)
run_as() { if [ "$(id -u)" -eq 0 ] && [ "$user" != root ]; then sudo -H -u "$user" env HOME="$home" USER="$user" LOGNAME="$user" "$@"; else env HOME="$home" USER="$user" LOGNAME="$user" "$@"; fi; }
install_framework() {
  if [ ! -d "$home/.oh-my-zsh" ]; then
    tmp=$(mktemp)
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$tmp"
    run_as env RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$tmp" --unattended
    rm -f "$tmp"
  fi
  custom="$home/.oh-my-zsh/custom/plugins"
  run_as mkdir -p "$custom"
  while IFS=$'\t' read -r name repo marker; do
    [ -n "$name" ] || continue
    if [ ! -f "$custom/$name/$marker" ]; then
      rm -rf "$custom/$name"
      run_as git clone -q --depth 1 "$repo" "$custom/$name"
    fi
    [ -f "$custom/$name/$marker" ] || { echo "Oh My Zsh plugin verification failed: $name/$marker" >&2; return 1; }
  done < <(jq -r '(.framework.external_plugins // [])[] | [.name,.repository,.marker] | @tsv' "$PORTALGUN_PROFILE_FILE")
}
case "${1:-}" in
  install) install_framework ;;
  verify)
    [ -d "$home/.oh-my-zsh" ] || exit 1
    while IFS=$'\t' read -r name _ marker; do [ -f "$home/.oh-my-zsh/custom/plugins/$name/$marker" ] || exit 1; done < <(jq -r '(.framework.external_plugins // [])[] | [.name,.repository,.marker] | @tsv' "$PORTALGUN_PROFILE_FILE")
    ;;
  describe) echo 'Oh My Zsh' ;;
  *) exit 64 ;;
esac
