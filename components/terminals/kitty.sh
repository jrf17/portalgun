#!/usr/bin/env bash
set -e
case "${1:-}" in
  install) command -v kitty >/dev/null 2>&1 || { [ "$(id -u)" -eq 0 ] && apt-get install -y kitty || sudo apt-get install -y kitty; } ;;
  verify) command -v kitty >/dev/null 2>&1 ;;
  describe) echo 'Kitty terminal emulator' ;;
  *) exit 64 ;;
esac
