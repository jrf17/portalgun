#!/usr/bin/env bash
set -e
case "${1:-}" in
  install) command -v alacritty >/dev/null 2>&1 || { [ "$(id -u)" -eq 0 ] && apt-get install -y alacritty || sudo apt-get install -y alacritty; } ;;
  verify) command -v alacritty >/dev/null 2>&1 ;;
  describe) echo 'Alacritty terminal emulator' ;;
  *) exit 64 ;;
esac
