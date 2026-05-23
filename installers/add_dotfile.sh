#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Add Dotfile to Website
# Copies a dotfile and adds it to the manifest
# ═══════════════════════════════════════════════════════════════════

DOTFILES_DIR="/opt/tools-docs/dotfiles"
MANIFEST="$DOTFILES_DIR/manifest.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

if [ $# -lt 1 ]; then
    echo "Usage: $0 <dotfile_path> [name] [target] [description] [category]"
    echo ""
    echo "Examples:"
    echo "  $0 ~/.vimrc"
    echo "  $0 ~/.tmux.conf 'Tmux Config' '~/.tmux.conf' 'Tmux with vim keys' 'terminal'"
    echo ""
    echo "Categories: shell, terminal, editor, misc"
    exit 1
fi

SOURCE_FILE="$1"
FILENAME=$(basename "$SOURCE_FILE")

# Remove leading dot for display name if present
DISPLAY_NAME="${FILENAME#.}"

# Defaults
NAME="${2:-$DISPLAY_NAME Config}"
TARGET="${3:-~/$FILENAME}"
DESC="${4:-Configuration file for $DISPLAY_NAME}"
CATEGORY="${5:-misc}"

# Generate ID from filename
ID=$(echo "$FILENAME" | tr '.' '_' | tr '-' '_' | tr '[:upper:]' '[:lower:]')

if [ ! -f "$SOURCE_FILE" ]; then
    print_error "File not found: $SOURCE_FILE"
    exit 1
fi

print_status "Adding dotfile: $FILENAME"
print_status "  Name: $NAME"
print_status "  Target: $TARGET"
print_status "  Category: $CATEGORY"

# Copy file
cp "$SOURCE_FILE" "$DOTFILES_DIR/$FILENAME"
print_success "Copied to $DOTFILES_DIR/$FILENAME"

# Update manifest using jq if available, otherwise manual append
if command -v jq &> /dev/null; then
    # Check if entry already exists
    if jq -e ".dotfiles[] | select(.id == \"$ID\")" "$MANIFEST" > /dev/null 2>&1; then
        print_status "Entry already exists, updating..."
        jq ".dotfiles = [.dotfiles[] | if .id == \"$ID\" then {id:\"$ID\",name:\"$NAME\",file:\"$FILENAME\",target:\"$TARGET\",description:\"$DESC\",category:\"$CATEGORY\",requires:[]} else . end]" "$MANIFEST" > "$MANIFEST.tmp"
    else
        jq ".dotfiles += [{id:\"$ID\",name:\"$NAME\",file:\"$FILENAME\",target:\"$TARGET\",description:\"$DESC\",category:\"$CATEGORY\",requires:[]}]" "$MANIFEST" > "$MANIFEST.tmp"
    fi
    mv "$MANIFEST.tmp" "$MANIFEST"
    print_success "Manifest updated"
else
    print_error "jq not installed. Please manually add to $MANIFEST:"
    echo ""
    echo "    {"
    echo "      \"id\": \"$ID\","
    echo "      \"name\": \"$NAME\","
    echo "      \"file\": \"$FILENAME\","
    echo "      \"target\": \"$TARGET\","
    echo "      \"description\": \"$DESC\","
    echo "      \"category\": \"$CATEGORY\","
    echo "      \"requires\": []"
    echo "    }"
fi

print_success "Done! Dotfile available at http://<ip>:1337 -> Config Manager"
