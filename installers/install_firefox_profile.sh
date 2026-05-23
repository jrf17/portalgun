#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Firefox Profile Installation Script
# Restores ~/.mozilla/firefox from a seed tarball captured in portalgun/seeds
# ═══════════════════════════════════════════════════════════════════

set -e

SEED_DIR="${SEED_DIR:-$HOME/portalgun/seeds/firefox_seed}"
SEED_FILE="$SEED_DIR/firefox_profile.tgz"
MOZ_DIR="$HOME/.mozilla"
FF_DIR="$MOZ_DIR/firefox"
BACKUP_DIR="$MOZ_DIR/firefox.bak.$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[-]${NC} $1"; }

if [ "$EUID" -eq 0 ]; then
    print_error "Do NOT run as root — this restores into your user home"
    exit 1
fi

if [ ! -f "$SEED_FILE" ]; then
    print_error "Seed not found: $SEED_FILE"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "           Firefox Profile Restore"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  Seed:    $SEED_FILE ($(du -h "$SEED_FILE" | cut -f1))"
echo "  Target:  $FF_DIR"
echo ""

if pgrep -x firefox >/dev/null || pgrep -x firefox-esr >/dev/null; then
    print_status "Firefox is running — closing it..."
    pkill -x firefox || true
    pkill -x firefox-esr || true
    for i in $(seq 1 10); do
        pgrep -x firefox >/dev/null || pgrep -x firefox-esr >/dev/null || break
        sleep 1
    done
    if pgrep -x firefox >/dev/null || pgrep -x firefox-esr >/dev/null; then
        print_warning "Firefox still running, sending SIGKILL"
        pkill -9 -x firefox || true
        pkill -9 -x firefox-esr || true
        sleep 2
    fi
    print_success "Firefox closed"
fi

if [ -d "$FF_DIR" ]; then
    print_status "Backing up existing profile to $BACKUP_DIR"
    mv "$FF_DIR" "$BACKUP_DIR"
fi

mkdir -p "$MOZ_DIR"
print_status "Extracting seed..."
tar xzf "$SEED_FILE" -C "$MOZ_DIR"
print_success "Profile restored"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "           ${GREEN}Firefox Profile Restore Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Restored to:  $FF_DIR"
if [ -d "$BACKUP_DIR" ]; then
    echo "Old profile:  $BACKUP_DIR (remove when you're sure restore worked)"
fi
echo ""
echo "Start Firefox normally — extensions, passwords, and bookmarks should be in place."
echo ""

exit 0
