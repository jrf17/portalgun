#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Kali Linux Terminal Setup Script
# Configures: Kitty, Zsh, Oh-My-Zsh, Starship, FZF, Zoxide, Yazi, etc.
# ═══════════════════════════════════════════════════════════════════

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ───────────────────────────────────────────────────────────────────
# Check if running as root
# ───────────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    print_error "Please run as normal user, not root"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "           Kali Linux Terminal Environment Setup"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────────────
# Update and install packages
# ───────────────────────────────────────────────────────────────────
print_status "Updating package lists..."
sudo apt update

print_status "Installing packages..."
sudo apt install -y \
    kitty \
    zsh \
    tmux \
    git \
    curl \
    wget \
    unzip \
    fontconfig \
    eza \
    bat \
    fd-find \
    ripgrep \
    btop \
    neovim \
    xclip \
    jq

print_success "Packages installed"

# ───────────────────────────────────────────────────────────────────
# Install Oh-My-Zsh
# ───────────────────────────────────────────────────────────────────
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    print_status "Installing Oh-My-Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    print_success "Oh-My-Zsh installed"
else
    print_warning "Oh-My-Zsh already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Zsh plugins
# ───────────────────────────────────────────────────────────────────
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    print_status "Installing zsh-syntax-highlighting..."
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    print_status "Installing zsh-autosuggestions..."
    git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

print_success "Zsh plugins installed"

# ───────────────────────────────────────────────────────────────────
# Install FZF
# ───────────────────────────────────────────────────────────────────
if [ ! -d "$HOME/.fzf" ]; then
    print_status "Installing FZF..."
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
    ~/.fzf/install --all --no-bash --no-fish
    print_success "FZF installed"
else
    print_warning "FZF already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Zoxide
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.local/bin/zoxide" ]; then
    print_status "Installing Zoxide..."
    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
    print_success "Zoxide installed"
else
    print_warning "Zoxide already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Starship
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.local/bin/starship" ]; then
    print_status "Installing Starship..."
    curl -sS https://starship.rs/install.sh | sh -s -- -y -b ~/.local/bin
    print_success "Starship installed"
else
    print_warning "Starship already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Yazi
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.local/bin/yazi" ]; then
    print_status "Installing Yazi..."
    YAZI_URL=$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest | jq -r '.assets[] | select(.name == "yazi-x86_64-unknown-linux-gnu.zip") | .browser_download_url')
    cd /tmp
    curl -sLO "$YAZI_URL"
    unzip -o yazi-x86_64-unknown-linux-gnu.zip
    mv yazi-x86_64-unknown-linux-gnu/yazi ~/.local/bin/
    mv yazi-x86_64-unknown-linux-gnu/ya ~/.local/bin/
    rm -rf yazi-x86_64-unknown-linux-gnu*
    print_success "Yazi installed"
else
    print_warning "Yazi already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Lazygit
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.local/bin/lazygit" ]; then
    print_status "Installing Lazygit..."
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | jq -r .tag_name | tr -d v)
    cd /tmp
    curl -sLO "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar xzf "lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" lazygit
    mv lazygit ~/.local/bin/
    rm -f "lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    print_success "Lazygit installed"
else
    print_warning "Lazygit already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Tealdeer (tldr)
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.local/bin/tldr" ]; then
    print_status "Installing Tealdeer (tldr)..."
    curl -sL https://github.com/tealdeer-rs/tealdeer/releases/latest/download/tealdeer-linux-x86_64-musl -o ~/.local/bin/tldr
    chmod +x ~/.local/bin/tldr
    ~/.local/bin/tldr --update
    print_success "Tealdeer installed"
else
    print_warning "Tealdeer already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install Zellij
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.local/bin/zellij" ]; then
    print_status "Installing Zellij..."
    ZELLIJ_URL=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | jq -r '.assets[] | select(.name | test("zellij-x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url')
    cd /tmp
    curl -sLO "$ZELLIJ_URL"
    tar xzf zellij-x86_64-unknown-linux-musl.tar.gz
    mv zellij ~/.local/bin/
    rm -f zellij-x86_64-unknown-linux-musl.tar.gz
    print_success "Zellij installed"
else
    print_warning "Zellij already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install TPM (Tmux Plugin Manager)
# ───────────────────────────────────────────────────────────────────
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    print_status "Installing TPM (Tmux Plugin Manager)..."
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    print_success "TPM installed"
else
    print_warning "TPM already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Install JetBrains Mono Nerd Font
# ───────────────────────────────────────────────────────────────────
if [ ! -d "$HOME/.local/share/fonts/JetBrainsMono" ]; then
    print_status "Installing JetBrains Mono Nerd Font..."
    mkdir -p ~/.local/share/fonts
    cd ~/.local/share/fonts
    curl -sLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
    unzip -o JetBrainsMono.zip -d JetBrainsMono
    rm JetBrainsMono.zip
    fc-cache -fv > /dev/null 2>&1
    print_success "JetBrains Mono Nerd Font installed"
else
    print_warning "JetBrains Mono Nerd Font already installed, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# Copy configuration files
# ───────────────────────────────────────────────────────────────────
print_status "Copying configuration files..."

mkdir -p ~/.config/kitty
mkdir -p ~/.config/yazi
mkdir -p ~/.config/zellij/layouts
mkdir -p ~/.config/zellij/scripts
mkdir -p ~/.config/zellij/plugins

cp "$SCRIPT_DIR/configs/zshrc" ~/.zshrc
cp "$SCRIPT_DIR/configs/starship.toml" ~/.config/starship.toml
cp "$SCRIPT_DIR/configs/kitty.conf" ~/.config/kitty/kitty.conf
cp "$SCRIPT_DIR/configs/tmux.conf" ~/.tmux.conf

# Copy Zellij configs
cp "$SCRIPT_DIR/configs/zellij/config.kdl" ~/.config/zellij/
cp "$SCRIPT_DIR/configs/zellij/themes.kdl" ~/.config/zellij/
cp "$SCRIPT_DIR/configs/zellij/layouts/default.kdl" ~/.config/zellij/layouts/
cp "$SCRIPT_DIR/configs/zellij/scripts/"*.sh ~/.config/zellij/scripts/
cp "$SCRIPT_DIR/configs/zellij/plugins/zjstatus.wasm" ~/.config/zellij/plugins/
chmod +x ~/.config/zellij/scripts/*.sh

print_success "Configuration files copied"

# ───────────────────────────────────────────────────────────────────
# Install Tmux plugins
# ───────────────────────────────────────────────────────────────────
print_status "Installing Tmux plugins..."
if [ -f "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
    "$HOME/.tmux/plugins/tpm/bin/install_plugins" > /dev/null 2>&1
    print_success "Tmux plugins installed"
else
    print_warning "TPM not found, plugins will install on first tmux launch"
    print_status "Run 'prefix + I' in tmux to install plugins"
fi

# ───────────────────────────────────────────────────────────────────
# Set Zsh as default shell
# ───────────────────────────────────────────────────────────────────
if [ "$SHELL" != "/usr/bin/zsh" ]; then
    print_status "Setting Zsh as default shell..."
    sudo chsh -s /usr/bin/zsh "$USER"
    print_success "Zsh set as default shell"
else
    print_warning "Zsh is already the default shell"
fi

# ───────────────────────────────────────────────────────────────────
# Enable SSH (optional)
# ───────────────────────────────────────────────────────────────────
print_status "Enabling SSH service..."
sudo systemctl enable --now ssh 2>/dev/null || true
print_success "SSH enabled"

# ───────────────────────────────────────────────────────────────────
# Setup Tools Documentation Server
# ───────────────────────────────────────────────────────────────────
print_status "Setting up tools documentation server..."
if [ -f "$SCRIPT_DIR/setup_tools_server.sh" ]; then
    bash "$SCRIPT_DIR/setup_tools_server.sh"
fi

# ───────────────────────────────────────────────────────────────────
# Start tools server
# ───────────────────────────────────────────────────────────────────
print_status "Starting tools server..."
sudo systemctl enable tools-server 2>/dev/null || true
sudo systemctl start tools-server 2>/dev/null || true

# ───────────────────────────────────────────────────────────────────
# Done
# ───────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}Setup Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Installed tools:"
echo "  - Kitty terminal (Catppuccin Mocha theme)"
echo "  - Zsh with Oh-My-Zsh"
echo "  - Starship prompt"
echo "  - Tmux (Catppuccin Mocha + TPM plugins)"
echo "  - FZF (fuzzy finder)"
echo "  - Zoxide (smart cd)"
echo "  - Eza (modern ls)"
echo "  - Bat (modern cat)"
echo "  - Ripgrep (modern grep)"
echo "  - Fd (modern find)"
echo "  - Yazi (file manager)"
echo "  - Lazygit (git TUI)"
echo "  - Btop (system monitor)"
echo "  - Neovim"
echo "  - Tealdeer (tldr)"
echo "  - Zellij (terminal multiplexer with zjstatus)"
echo ""
echo "Tools Server: http://$IP:1337"
echo "  - Tools documentation and search"
echo "  - Config Manager (Zsh, Zellij)"
echo "  - Custom hotkey editor"
echo ""
echo "Please log out and back in, or run: exec zsh"
echo ""
