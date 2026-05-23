#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Kali Linux Libraries Installation Script
# Installs missing libraries (attempts version matching)
# ═══════════════════════════════════════════════════════════════════

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "              Kali Linux Libraries Installation"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Libraries to install (from missing list)
LIBRARIES=(
    "libamd-comgr2"
    "libamdhip64-5"
    "libavcodec61"
    "libavutil59"
    "libblosc2-4"
    "libboost-system1.83-dev"
    "libcdt5"
    "libcgraph6"
    "libdlt2"
    "libgtk-4-media-gstreamer"
    "libgusb2"
    "libgvc6"
    "libnode115"
    "libonnxruntime1.21"
    "libopenexr-3-1-30"
    "libpkgconf3"
    "libplacebo351"
    "libpyside6-py3-6.9"
    "libqwt-qt5-6"
    "librav1e0.7"
    "libsframe2"
    "libshiboken6-py3-6.9"
    "libsimdutf27"
    "libsimdutf29"
    "libswresample5"
    "libtheoradec1"
    "libtheoraenc1"
    "libvolk3.2"
    "libvpx11"
    "libx264-164"
    "libxml2"
    "libyelp0"
)

INSTALLED=0
FAILED=0
SKIPPED=0
FAILED_LIST=()

print_status "Updating package lists..."
sudo apt update
echo ""

print_status "Installing ${#LIBRARIES[@]} libraries..."
echo ""

for lib in "${LIBRARIES[@]}"; do
    echo -ne "${BLUE}[*]${NC} $lib ... "

    # Check if already installed
    if dpkg -l "$lib" 2>/dev/null | grep -q "^ii"; then
        echo -e "${YELLOW}SKIP${NC} (already installed)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Try exact name first
    if apt-cache show "$lib" &>/dev/null; then
        if sudo apt install -y "$lib" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
            INSTALLED=$((INSTALLED + 1))
            continue
        fi
    fi

    # Try finding similar package (strip version numbers)
    BASE_NAME=$(echo "$lib" | sed -E 's/[0-9]+(\.[0-9]+)*(-[0-9]+)?$//' | sed 's/-$//')

    # Search for similar packages
    SIMILAR=$(apt-cache search "^${BASE_NAME}" 2>/dev/null | head -1 | awk '{print $1}')

    if [ -n "$SIMILAR" ] && [ "$SIMILAR" != "$lib" ]; then
        echo -ne "${YELLOW}trying $SIMILAR${NC} ... "
        if sudo apt install -y "$SIMILAR" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
            INSTALLED=$((INSTALLED + 1))
            continue
        fi
    fi

    # Try with wildcard search
    WILDCARD=$(apt-cache pkgnames "$BASE_NAME" 2>/dev/null | head -1)

    if [ -n "$WILDCARD" ] && [ "$WILDCARD" != "$lib" ]; then
        echo -ne "${YELLOW}trying $WILDCARD${NC} ... "
        if sudo apt install -y "$WILDCARD" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
            INSTALLED=$((INSTALLED + 1))
            continue
        fi
    fi

    echo -e "${RED}FAILED${NC} (not found in repos)"
    FAILED=$((FAILED + 1))
    FAILED_LIST+=("$lib")
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}Installation Complete${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Summary:"
echo -e "  Installed:  ${GREEN}$INSTALLED${NC}"
echo -e "  Skipped:    ${YELLOW}$SKIPPED${NC} (already installed)"
echo -e "  Failed:     ${RED}$FAILED${NC}"
echo ""

if [ ${#FAILED_LIST[@]} -gt 0 ]; then
    print_warning "Failed libraries (not in current repos):"
    for lib in "${FAILED_LIST[@]}"; do
        echo "  - $lib"
    done
    echo ""
    echo "These may have different version numbers in current Kali repos."
    echo "They'll be installed automatically as dependencies when needed."
fi
echo ""

exit 0
