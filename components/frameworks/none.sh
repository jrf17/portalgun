#!/usr/bin/env bash
case "${1:-}" in install|verify) exit 0;; describe) echo 'No shell framework; preserve Kali defaults';; *) exit 64;; esac
