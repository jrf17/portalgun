#!/usr/bin/env bash
set -e
case "${1:-}" in
  install) command -v tilix >/dev/null 2>&1 || { [ "$(id -u)" -eq 0 ] && apt-get install -y tilix || sudo apt-get install -y tilix; } ;;
  verify) command -v tilix >/dev/null 2>&1 ;;
  describe) echo 'Tilix terminal emulator' ;;
  *) exit 64 ;;
esac
