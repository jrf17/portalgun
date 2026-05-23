#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Kali Linux Tools Update Script
# Updates all tools: apt packages, cargo, and GitHub releases
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
echo "              Kali Linux Tools Update Script"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────────────
# Update APT packages
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating APT packages..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y

print_success "APT packages updated"
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Cargo/Rust tools
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Cargo/Rust tools..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if command -v cargo &> /dev/null; then
    # Update cargo itself
    rustup update 2>/dev/null || true

    # Update installed cargo tools
    CARGO_TOOLS=("rustscan" "feroxbuster")
    for tool in "${CARGO_TOOLS[@]}"; do
        if cargo install --list | grep -q "^$tool"; then
            print_status "Updating $tool..."
            cargo install "$tool" --force 2>/dev/null && print_success "$tool updated" || print_warning "$tool update failed"
        fi
    done
else
    print_warning "Cargo not installed, skipping Rust tools"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Starship
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Starship..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$HOME/.local/bin/starship" ]; then
    CURRENT_VER=$("$HOME/.local/bin/starship" --version | head -1 | awk '{print $2}')
    print_status "Current version: $CURRENT_VER"

    curl -sS https://starship.rs/install.sh | sh -s -- -y -b ~/.local/bin

    NEW_VER=$("$HOME/.local/bin/starship" --version | head -1 | awk '{print $2}')
    print_success "Starship updated: $CURRENT_VER -> $NEW_VER"
else
    print_warning "Starship not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Zoxide
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Zoxide..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$HOME/.local/bin/zoxide" ]; then
    CURRENT_VER=$("$HOME/.local/bin/zoxide" --version | awk '{print $2}')
    print_status "Current version: $CURRENT_VER"

    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash

    NEW_VER=$("$HOME/.local/bin/zoxide" --version | awk '{print $2}')
    print_success "Zoxide updated: $CURRENT_VER -> $NEW_VER"
else
    print_warning "Zoxide not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Yazi
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Yazi..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$HOME/.local/bin/yazi" ]; then
    CURRENT_VER=$("$HOME/.local/bin/yazi" --version 2>/dev/null | head -1 | awk '{print $2}')
    print_status "Current version: $CURRENT_VER"

    YAZI_URL=$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest | jq -r '.assets[] | select(.name == "yazi-x86_64-unknown-linux-gnu.zip") | .browser_download_url')

    if [ -n "$YAZI_URL" ]; then
        cd /tmp
        curl -sLO "$YAZI_URL"
        unzip -o yazi-x86_64-unknown-linux-gnu.zip
        mv yazi-x86_64-unknown-linux-gnu/yazi ~/.local/bin/
        mv yazi-x86_64-unknown-linux-gnu/ya ~/.local/bin/
        rm -rf yazi-x86_64-unknown-linux-gnu*

        NEW_VER=$("$HOME/.local/bin/yazi" --version 2>/dev/null | head -1 | awk '{print $2}')
        print_success "Yazi updated: $CURRENT_VER -> $NEW_VER"
    else
        print_error "Failed to fetch Yazi download URL"
    fi
else
    print_warning "Yazi not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Lazygit
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Lazygit..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$HOME/.local/bin/lazygit" ]; then
    CURRENT_VER=$("$HOME/.local/bin/lazygit" --version | grep -oP 'version=\K[^,]+')
    print_status "Current version: $CURRENT_VER"

    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | jq -r .tag_name | tr -d v)

    if [ -n "$LAZYGIT_VERSION" ]; then
        cd /tmp
        curl -sLO "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
        tar xzf "lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" lazygit
        mv lazygit ~/.local/bin/
        rm -f "lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"

        NEW_VER=$("$HOME/.local/bin/lazygit" --version | grep -oP 'version=\K[^,]+')
        print_success "Lazygit updated: $CURRENT_VER -> $NEW_VER"
    else
        print_error "Failed to fetch Lazygit version"
    fi
else
    print_warning "Lazygit not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Tealdeer (tldr)
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Tealdeer (tldr)..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$HOME/.local/bin/tldr" ]; then
    CURRENT_VER=$("$HOME/.local/bin/tldr" --version 2>/dev/null)
    print_status "Current version: $CURRENT_VER"

    curl -sL https://github.com/tealdeer-rs/tealdeer/releases/latest/download/tealdeer-linux-x86_64-musl -o ~/.local/bin/tldr
    chmod +x ~/.local/bin/tldr

    # Update tldr cache
    "$HOME/.local/bin/tldr" --update

    NEW_VER=$("$HOME/.local/bin/tldr" --version 2>/dev/null)
    print_success "Tealdeer updated: $CURRENT_VER -> $NEW_VER"
else
    print_warning "Tealdeer not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Zellij
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Zellij..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -f "$HOME/.local/bin/zellij" ]; then
    CURRENT_VER=$("$HOME/.local/bin/zellij" --version 2>/dev/null | awk '{print $2}')
    print_status "Current version: $CURRENT_VER"

    ZELLIJ_URL=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | jq -r '.assets[] | select(.name | test("zellij-x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url')

    if [ -n "$ZELLIJ_URL" ]; then
        cd /tmp
        curl -sLO "$ZELLIJ_URL"
        tar xzf zellij-x86_64-unknown-linux-musl.tar.gz
        mv zellij ~/.local/bin/
        rm -f zellij-x86_64-unknown-linux-musl.tar.gz

        NEW_VER=$("$HOME/.local/bin/zellij" --version 2>/dev/null | awk '{print $2}')
        print_success "Zellij updated: $CURRENT_VER -> $NEW_VER"
    else
        print_error "Failed to fetch Zellij download URL"
    fi
else
    print_warning "Zellij not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update Oh-My-Zsh and plugins
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating Oh-My-Zsh and plugins..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -d "$HOME/.oh-my-zsh" ]; then
    # Update Oh-My-Zsh
    print_status "Updating Oh-My-Zsh..."
    cd "$HOME/.oh-my-zsh" && git pull --quiet
    print_success "Oh-My-Zsh updated"

    # Update plugins
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    for plugin_dir in "$ZSH_CUSTOM/plugins"/*; do
        if [ -d "$plugin_dir/.git" ]; then
            plugin_name=$(basename "$plugin_dir")
            print_status "Updating plugin: $plugin_name..."
            cd "$plugin_dir" && git pull --quiet
            print_success "$plugin_name updated"
        fi
    done
else
    print_warning "Oh-My-Zsh not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Update FZF
# ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_status "Updating FZF..."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -d "$HOME/.fzf" ]; then
    cd "$HOME/.fzf" && git pull --quiet && ./install --all --no-bash --no-fish --no-update-rc
    print_success "FZF updated"
else
    print_warning "FZF not installed, skipping"
fi
echo ""

# ───────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}Update Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Updated:"
echo "  - APT packages"
echo "  - Cargo/Rust tools (if installed)"
echo "  - Starship prompt"
echo "  - Zoxide"
echo "  - Yazi"
echo "  - Lazygit"
echo "  - Tealdeer (tldr)"
echo "  - Zellij"
echo "  - Oh-My-Zsh + plugins"
echo "  - FZF"
echo ""
