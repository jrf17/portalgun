#!/usr/bin/env bash
case "${1:-}" in install|verify) exit 0;; describe) echo 'Preserve Kali default shell';; *) exit 64;; esac
