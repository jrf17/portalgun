#!/bin/bash
# portalgun common helpers — sourced by all lib/* and bin/portalgun

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[*]${NC} $*"; }
print_success() { echo -e "${GREEN}[+]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $*"; }
print_error()   { echo -e "${RED}[-]${NC} $*" >&2; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This command needs root. Try: sudo portalgun $*"
        exit 1
    fi
}

require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Required commands not found: ${missing[*]}"
        print_status "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$PORTALGUN_REGISTRY/apt" "$PORTALGUN_REGISTRY/github" "$PORTALGUN_LOG_DIR"
}
