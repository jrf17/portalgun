#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Kali Linux Master Setup Script
# Installs EVERYTHING: terminal env, libraries, tools, GitHub tools
# ═══════════════════════════════════════════════════════════════════

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Repository paths and profile-aware argument parsing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/master_install.log"
DEBUG_LOG="$SCRIPT_DIR/master_debug.log"
PORTALGUN_PROFILE_ROOT="$SCRIPT_DIR/profiles"
PORTALGUN_COMPONENT_ROOT="$SCRIPT_DIR/components"
export PORTALGUN_PROFILE_ROOT PORTALGUN_COMPONENT_ROOT PORTALGUN_REPO_DIR="$SCRIPT_DIR"

# shellcheck source=lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"

DEBUG_MODE=false
PROFILE_NAME=""
CREATE_PROFILE=""
VALIDATE_ONLY=false
NON_INTERACTIVE=false
TARGET_USER="${USER}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --profile NAME          Use a terminal profile
  --create-profile NAME   Create a profile interactively and exit
  --validate-profile      Validate the selected profile and exit
  --target-user USER      Apply the profile to USER (default: $USER)
  --non-interactive       Require an explicit profile and skip confirmation
  --debug, -d             Enable debug mode with verbose logging
  --help, -h              Show this help message

Without --profile, an interactive terminal presents the available profiles.
The provider value "none" preserves the corresponding Kali default.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            [ "$#" -ge 2 ] || { echo "--profile requires a name" >&2; exit 64; }
            PROFILE_NAME="$2"; shift 2 ;;
        --profile=*) PROFILE_NAME="${1#*=}"; shift ;;
        --create-profile)
            [ "$#" -ge 2 ] || { echo "--create-profile requires a name" >&2; exit 64; }
            CREATE_PROFILE="$2"; shift 2 ;;
        --create-profile=*) CREATE_PROFILE="${1#*=}"; shift ;;
        --validate-profile) VALIDATE_ONLY=true; shift ;;
        --target-user)
            [ "$#" -ge 2 ] || { echo "--target-user requires a username" >&2; exit 64; }
            TARGET_USER="$2"; shift 2 ;;
        --target-user=*) TARGET_USER="${1#*=}"; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --debug|-d) DEBUG_MODE=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
    esac
done

# Profile selection and validation require jq before Phase 1 begins.
ensure_profile_prerequisites() {
    command -v jq >/dev/null 2>&1 && return 0

    echo "[*] Installing required profile parser: jq"

    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq
    else
        command -v sudo >/dev/null 2>&1 || {
            echo "sudo is required to install jq" >&2
            return 1
        }

        sudo apt-get update -q
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq
    fi

    command -v jq >/dev/null 2>&1 || {
        echo "jq installation failed" >&2
        return 1
    }
}

ensure_profile_prerequisites

if [ -n "$CREATE_PROFILE" ]; then
    profile_create "$CREATE_PROFILE"
    exit $?
fi

if [ -z "$PROFILE_NAME" ]; then
    if [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
        echo "--profile is required for non-interactive installation" >&2
        exit 64
    fi
    PROFILE_NAME="$(profile_select_interactive)"
fi

profile_validate "$PROFILE_NAME" || exit 1
if [ "$VALIDATE_ONLY" = true ]; then
    exit 0
fi

id "$TARGET_USER" >/dev/null 2>&1 || { echo "Target user not found: $TARGET_USER" >&2; exit 1; }
export PORTALGUN_PROFILE="$PROFILE_NAME" PORTALGUN_TARGET_USER="$TARGET_USER"

# Output functions - quiet in normal mode, verbose in debug
print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

# Run command - verbose to screen in debug, quiet to screen but logged in normal mode
run_quiet() {
    if [ "$DEBUG_MODE" = true ]; then
        "$@"
    else
        "$@" >> "$LOG_FILE" 2>&1
    fi
}

# Wait for apt locks to be released
wait_for_apt() {
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo -n "."
        sleep 2
    done
}

# Run apt - shows progress in both modes, suppresses restart notices
apt_install() {
    wait_for_apt
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
        apt-get install -y --show-progress -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@" 2>&1 | \
        tee -a "$LOG_FILE" | grep -v -E "(Reading database|Preparing to unpack|Selecting previously|WARNING:|Restarting services|needrestart|Scanning processes|Scanning candidates|Scanning linux)" || true
}

# Debug mode setup
if [ "$DEBUG_MODE" = true ]; then
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  DEBUG MODE ENABLED"
    echo "  All output will be logged to: $DEBUG_LOG"
    echo "═══════════════════════════════════════════════════════════════════"
    > "$DEBUG_LOG"
    exec > >(while IFS= read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" | tee -a "$DEBUG_LOG"; done) 2>&1
    set -x
    echo "DEBUG: Script started at $(date)"
    echo "DEBUG: Running as user: $USER"
    echo "DEBUG: Script directory: $SCRIPT_DIR"
    echo "DEBUG: System info: $(uname -a)"
    echo ""
fi

# ───────────────────────────────────────────────────────────────────
# Pre-flight checks
# ───────────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    print_error "Please run as normal user, not root"
    exit 1
fi

if ! grep -q "Kali" /etc/os-release 2>/dev/null; then
    print_warning "This doesn't appear to be Kali Linux. Continue anyway? (y/n)"
    read -r response
    [[ ! "$response" =~ ^[Yy]$ ]] && exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "           Kali Linux Master Setup"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
profile_summary "$PORTALGUN_PROFILE"
echo ""
echo "This will install:"
echo "  1. Profile-driven terminal environment"
echo "  2. System libraries"
echo "  3. Kali tools from apt repositories"
echo "  4. Security tools from GitHub"
echo "  5. Tools documentation webserver"
echo "  6. BloodHound CE (Docker, port 1338, seed-restored)"
echo "  7. Firefox profile (extensions, saved logins) from seed"
echo "  8. portalgun (tool installer + symlink manager + VM clone helper)"
echo ""
if [ "$NON_INTERACTIVE" != true ]; then
    print_warning "Press ENTER to continue or Ctrl+C to abort..."
    read -r
fi

# Start logging
> "$LOG_FILE"  # Clear/create log file
if [ "$DEBUG_MODE" = false ]; then
    # Tee status messages to both screen and log
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "Installation started: $(date)"
echo "═══════════════════════════════════════════════════════════════════"

# ───────────────────────────────────────────────────────────────────
# Configure system for non-interactive install
# ───────────────────────────────────────────────────────────────────
print_status "Configuring system for non-interactive install..."

TEMP_SUDO_FILE="/etc/sudoers.d/temp_install"

cleanup_install_state() {
    local rc=$?

    sudo rm -f "$TEMP_SUDO_FILE" 2>/dev/null || true

    trap - EXIT INT TERM
    exit "$rc"
}

trap cleanup_install_state EXIT INT TERM

# Passwordless sudo
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee "$TEMP_SUDO_FILE" > /dev/null
sudo chmod 440 "$TEMP_SUDO_FILE"

# Suppress ALL interactive prompts and restart notices
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Completely disable needrestart prompts
sudo mkdir -p /etc/needrestart/conf.d/
sudo tee /etc/needrestart/conf.d/disable-prompts.conf > /dev/null << 'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
$nrconf{ucodehints} = 0;
EOF

# Disable apt CLI warnings
export APT_LISTCHANGES_FRONTEND=none

# ───────────────────────────────────────────────────────────────────
# PHASE 1: System Update
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 1/10: System Update${NC}                              [0%]"
echo "═══════════════════════════════════════════════════════════════════"

print_status "Updating package lists..."
wait_for_apt
sudo apt-get update -q 2>&1 | tee -a "$LOG_FILE" | grep -E "^(Get:|Hit:|Fetched|Reading)" || true

# Install essential tools needed by this script FIRST
print_status "Installing script dependencies..."
wait_for_apt
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl wget git jq unzip rsync >> "$LOG_FILE" 2>&1

print_status "Upgrading existing packages..."
wait_for_apt
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get upgrade -y --show-progress -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" 2>&1 | \
    tee -a "$LOG_FILE" | grep -v -E "(Reading database|Preparing to unpack|Selecting previously|WARNING:|Restarting services|needrestart|Scanning processes|Scanning candidates|Scanning linux)" || true

print_success "System updated"

# ───────────────────────────────────────────────────────────────────
# PHASE 2: Terminal Environment
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 2/12: Terminal Profile${NC}                           [10%]"
echo "═══════════════════════════════════════════════════════════════════"

# Packages needed by later Portalgun phases regardless of terminal profile.
print_status "Installing shared runtime packages..."
apt_install python3-pip python3-venv python3-flask

print_status "Applying terminal profile '$PORTALGUN_PROFILE' to $PORTALGUN_TARGET_USER..."
profile_apply "$PORTALGUN_PROFILE" "$PORTALGUN_TARGET_USER"
print_success "Terminal profile installed"

# ───────────────────────────────────────────────────────────────────
# PHASE 3: Libraries
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 3/10: System Libraries${NC}                            [20%]"
echo "═══════════════════════════════════════════════════════════════════"

if [ -f "$SCRIPT_DIR/installers/install_libraries.sh" ]; then
    print_status "Installing system libraries..."
    if [ "$DEBUG_MODE" = true ]; then
        sudo bash "$SCRIPT_DIR/installers/install_libraries.sh" || print_warning "Some libraries may have failed"
    else
        # Show progress - filter for key status lines
        sudo bash "$SCRIPT_DIR/installers/install_libraries.sh" 2>&1 | tee -a "$LOG_FILE" | grep --line-buffered -E "^\[.\]|FAILED|installed|Installing" || true
    fi
    print_success "Libraries installed"
else
    print_warning "install_libraries.sh not found, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 4: Kali Tools from APT
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 4/10: Kali Tools (APT)${NC}                            [30%]"
echo "═══════════════════════════════════════════════════════════════════"

if [ -f "$SCRIPT_DIR/installers/install_tools.sh" ]; then
    print_status "Installing Kali tools from apt..."
    if [ "$DEBUG_MODE" = true ]; then
        bash "$SCRIPT_DIR/installers/install_tools.sh" || print_warning "Some tools may have failed"
    else
        # Show progress - filter for key status lines
        bash "$SCRIPT_DIR/installers/install_tools.sh" 2>&1 | tee -a "$LOG_FILE" | grep --line-buffered -E "^\[.\]|FAILED|OK$|Installed:|Missing:|Batch|Retrying" || true
    fi
    print_success "Kali tools installed"
else
    print_warning "install_tools.sh not found, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 5: GitHub Security Tools
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 5/10: GitHub Security Tools${NC}                      [40%]"
echo "═══════════════════════════════════════════════════════════════════"

if [ -f "$SCRIPT_DIR/installers/install_github_tools.sh" ]; then
    print_status "Installing security tools from GitHub..."
    if [ "$DEBUG_MODE" = true ]; then
        sudo bash "$SCRIPT_DIR/installers/install_github_tools.sh" || print_warning "Some GitHub tools may have failed"
    else
        # Show progress - filter for key status lines
        sudo bash "$SCRIPT_DIR/installers/install_github_tools.sh" 2>&1 | tee -a "$LOG_FILE" | grep --line-buffered -E "^\[.\]|already installed|installed$|Downloading|Cloning|Creating" || true
    fi
    print_success "GitHub tools installed"
else
    print_warning "install_github_tools.sh not found, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 6: Tools Documentation Server
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 6/10: Tools Documentation Server${NC}                 [50%]"
echo "═══════════════════════════════════════════════════════════════════"

DOC_DIR="/opt/tools-docs"
DOTFILES_DIR="$DOC_DIR/dotfiles"

print_status "Setting up tools documentation server..."

sudo mkdir -p "$DOC_DIR"
sudo mkdir -p "$DOTFILES_DIR"/{zellij/{custom,p3ta_files/{layouts,plugins,scripts}},tmux/custom}
sudo chown -R "$USER:$USER" "$DOC_DIR"
sudo chmod -R 755 "$DOC_DIR"

cp "$SCRIPT_DIR/data/tools_readme.html" "$DOC_DIR/index.html" 2>/dev/null || true
cp "$SCRIPT_DIR/data/tools_server.py" "$DOC_DIR/tools_server.py" 2>/dev/null || true
cp "$SCRIPT_DIR/data/portalgun.png" "$DOC_DIR/portalgun.png" 2>/dev/null || true
[ -f "$SCRIPT_DIR/installers/install_github_tools.sh" ] && cp "$SCRIPT_DIR/installers/install_github_tools.sh" "$DOC_DIR/"

cp "$SCRIPT_DIR/configs/zshrc" "$DOTFILES_DIR/zshrc" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/zshrc_nerd" "$DOTFILES_DIR/zshrc_nerd" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/zshrc_kali_default" "$DOTFILES_DIR/zshrc_kali_default" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/kitty.conf" "$DOTFILES_DIR/kitty.conf" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/starship.toml" "$DOTFILES_DIR/starship.toml" 2>/dev/null || true

cp "$SCRIPT_DIR/zellij/"*.kdl "$DOTFILES_DIR/zellij/" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/zellij/themes.kdl" "$DOTFILES_DIR/zellij/p3ta_files/" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/zellij/layouts/"*.kdl "$DOTFILES_DIR/zellij/p3ta_files/layouts/" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/zellij/plugins/"* "$DOTFILES_DIR/zellij/p3ta_files/plugins/" 2>/dev/null || true
cp "$SCRIPT_DIR/configs/zellij/scripts/"* "$DOTFILES_DIR/zellij/p3ta_files/scripts/" 2>/dev/null || true

cp "$SCRIPT_DIR/tmux/"*.conf "$DOTFILES_DIR/tmux/" 2>/dev/null || true

cat > "$DOTFILES_DIR/manifest.json" << 'EOF'
{
  "dotfiles": [
    {
      "id": "zshrc_kali_default",
      "name": "Kali Default",
      "file": "zshrc_kali_default",
      "target": "~/.zshrc",
      "description": "Stock Kali Linux zshrc - unmodified default",
      "category": "shell",
      "requires": ["zsh"]
    },
    {
      "id": "zshrc_p3ta",
      "name": "p3ta",
      "file": "zshrc",
      "target": "~/.zshrc",
      "description": "Oh-My-Zsh with Starship, FZF, Zoxide, modern aliases",
      "category": "shell",
      "requires": ["zsh", "starship", "fzf", "zoxide", "eza", "bat"]
    },
    {
      "id": "zshrc_jp",
      "name": "JP",
      "file": "zshrc_nerd",
      "target": "~/.zshrc",
      "description": "Kali-style zshrc with NerdFonts glyphs, completion, history",
      "category": "shell",
      "requires": ["zsh", "nerdfonts"]
    }
  ]
}
EOF

chmod -R 755 "$DOC_DIR"
chmod 644 "$DOC_DIR"/*.html "$DOC_DIR"/*.py 2>/dev/null || true

sudo tee /etc/systemd/system/tools-server.service > /dev/null << EOF
[Unit]
Description=Kali Tools Documentation Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$DOC_DIR
ExecStart=/usr/bin/python3 $DOC_DIR/tools_server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

run_quiet sudo systemctl daemon-reload
run_quiet sudo systemctl enable tools-server
run_quiet sudo systemctl start tools-server

print_success "Tools server installed and started"

# ───────────────────────────────────────────────────────────────────
# PHASE 7: BloodHound CE
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 7/10: BloodHound CE${NC}                              [60%]"
echo "═══════════════════════════════════════════════════════════════════"

if ! command -v docker &>/dev/null; then
    print_status "Installing Docker..."
    apt_install docker.io docker-compose
fi

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    print_status "Installing docker-compose..."
    apt_install docker-compose
fi

if ! sudo docker info &>/dev/null; then
    print_status "Starting Docker daemon..."
    run_quiet sudo systemctl enable --now docker
fi

if [ -f "$SCRIPT_DIR/installers/install_bloodhound_ce.sh" ]; then
    print_status "Installing BloodHound CE (seed-restored)..."
    set +e
    sudo bash "$SCRIPT_DIR/installers/install_bloodhound_ce.sh" 2>&1 | tee -a "$LOG_FILE"
    bh_rc=${PIPESTATUS[0]}
    set -e
    if [ $bh_rc -eq 0 ]; then
        print_success "BloodHound CE installed"
    else
        print_warning "BloodHound install had issues — see $LOG_FILE"
    fi
else
    print_warning "install_bloodhound_ce.sh not found, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 8: Firefox Profile
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 8/10: Firefox Profile${NC}                            [70%]"
echo "═══════════════════════════════════════════════════════════════════"

if [ -f "$SCRIPT_DIR/installers/install_firefox_profile.sh" ]; then
    print_status "Restoring Firefox profile from seed..."
    set +e
    bash "$SCRIPT_DIR/installers/install_firefox_profile.sh" 2>&1 | tee -a "$LOG_FILE"
    ff_rc=${PIPESTATUS[0]}
    set -e
    if [ $ff_rc -eq 0 ]; then
        print_success "Firefox profile restored"
    else
        print_warning "Firefox restore had issues — see $LOG_FILE"
    fi
else
    print_warning "install_firefox_profile.sh not found, skipping"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 9: Final Setup
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 9/10: Final Setup${NC}                                 [80%]"
echo "═══════════════════════════════════════════════════════════════════"

print_status "Enabling SSH..."
run_quiet sudo systemctl enable --now ssh

# Add user to docker group so they can run `docker` and `bloodhound-ce` without sudo.
# Takes effect after logout/login. Until then, sudo is still needed.
if getent group docker >/dev/null; then
    print_status "Adding $USER to docker group..."
    sudo usermod -aG docker "$USER"
fi

# Configure the selected profile's terminal launcher. A terminal provider of
# "none" is a deliberate no-op that preserves Kali's existing launcher.
print_status "Configuring profile terminal launcher..."
profile_configure_panel "$PORTALGUN_PROFILE" "$PORTALGUN_TARGET_USER"

# Remove text editor from panel (plugin 5)
if command -v xfconf-query &>/dev/null; then
    xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids -rR 2>/dev/null || true
    xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids -n -a \
        -t int -s 1 -t int -s 2 -t int -s 3 -t int -s 4 \
        -t int -s 6 -t int -s 7 -t int -s 8 -t int -s 9 -t int -s 10 \
        -t int -s 11 -t int -s 12 -t int -s 13 -t int -s 14 -t int -s 15 \
        -t int -s 16 -t int -s 17 -t int -s 18 -t int -s 19 -t int -s 20 \
        -t int -s 21 -t int -s 22 2>/dev/null || true
fi

print_status "Cleaning up..."
run_quiet sudo apt-get autoremove -y
run_quiet sudo apt-get clean

# ───────────────────────────────────────────────────────────────────
# PHASE 10: portalgun
# ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${CYAN}PHASE 10/10: portalgun${NC}                                  [90%]"
echo "═══════════════════════════════════════════════════════════════════"

# portalgun lives in this repo — installers/portalgun_install.sh is the
# self-contained installer that copies the CLI to /opt/portalgun, sets up
# symlinks, web pages, firstboot service, etc.
print_status "Installing portalgun CLI..."
set +e
sudo bash "$SCRIPT_DIR/installers/portalgun_install.sh" 2>&1 | tee -a "$LOG_FILE"
pg_rc=${PIPESTATUS[0]}
set -e
if [ $pg_rc -eq 0 ]; then
    print_success "portalgun installed"
else
    print_warning "portalgun install had issues — see $LOG_FILE"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 10.5: Bundle replay — pip + cargo + registry backfill + manifest
# install.sh's earlier phases stage apt+github via legacy installers that don't
# touch the registry. We now run the portalgun bundle replay so that:
#   - pentest-venv is created and 800+ pip packages installed
#   - cargo crates are installed
#   - the registry under /var/lib/portalgun/registry/ is populated
#   - the web manifest /opt/tools-docs/portalgun_tools.json is generated
# Skip with PORTALGUN_SKIP_BUNDLE=1 for very fast iteration.
# ───────────────────────────────────────────────────────────────────
if [ "${PORTALGUN_SKIP_BUNDLE:-0}" != "1" ] && command -v portalgun >/dev/null 2>&1; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}PHASE 10b: Bundle replay (pip + cargo + register + sync_web)${NC}  [91%]"
    echo "═══════════════════════════════════════════════════════════════════"
    set +e
    # Full bundle replay. apply.sh is fully idempotent per-package; already-
    # installed entries are skipped fast (~50ms each).
    #   - apt: backfills the 12-or-so packages installable_packages.txt missed
    #   - github: clones the ~64 bundle entries the legacy script didn't cover
    #   - pip: creates pentest-venv and installs all spec'd packages
    #   - cargo: installs all crates
    #   - register_all + sync_web_manifest at the tail → populates /var/lib + manifest
    # Burp/Sliver still skipped here; they run as explicit Phase 11/12 below.
    PORTALGUN_SKIP_BURP=1 PORTALGUN_SKIP_SLIVER=1 \
        sudo -E env PORTALGUN_PROFILE="$PORTALGUN_PROFILE" \
          PORTALGUN_PROFILE_ROOT="/opt/portalgun/profiles" \
          PORTALGUN_COMPONENT_ROOT="/opt/portalgun/components" \
          PORTALGUN_TARGET_USER="$PORTALGUN_TARGET_USER" \
          bash -c "
            source /opt/portalgun/lib/common.sh
            source /opt/portalgun/lib/registry.sh
            source /opt/portalgun/lib/detect.sh
            source /opt/portalgun/lib/profile.sh
            source /opt/portalgun/lib/apply.sh
            apply_bundle /opt/portalgun/portalgun_bundle.json
          " 2>&1 | tee -a "$LOG_FILE"
    bundle_rc=${PIPESTATUS[0]}
    set -e
    if [ $bundle_rc -eq 0 ]; then
        print_success "Bundle replay complete — registry + manifest populated"
    else
        print_warning "Bundle replay had issues — run: portalgun verify"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 11: Burp Suite Pro (download + BApps + license import)
# Skip with PORTALGUN_SKIP_BURP=1 (saves ~10min and ~1GB during dev iterations).
# ───────────────────────────────────────────────────────────────────
if [ "${PORTALGUN_SKIP_BURP:-0}" != "1" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}PHASE 11/12: Burp Suite Pro + BApps${NC}                     [92%]"
    echo "═══════════════════════════════════════════════════════════════════"
    set +e
    sudo bash -c "source /opt/portalgun/lib/install_burp.sh && install_burp_pro" 2>&1 | tee -a "$LOG_FILE"
    burp_rc=${PIPESTATUS[0]}
    set -e
    [ $burp_rc -eq 0 ] && print_success "Burp Suite Pro installed" \
        || print_warning "Burp Pro install non-fatal failure (see $LOG_FILE)"
else
    print_status "Burp Pro install SKIPPED (PORTALGUN_SKIP_BURP=1)"
fi

# ───────────────────────────────────────────────────────────────────
# PHASE 12: Sliver C2 + armory preload
# Skip with PORTALGUN_SKIP_SLIVER=1
# ───────────────────────────────────────────────────────────────────
if [ "${PORTALGUN_SKIP_SLIVER:-0}" != "1" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}PHASE 12/12: Sliver C2 + Armory${NC}                         [96%]"
    echo "═══════════════════════════════════════════════════════════════════"
    set +e
    sudo bash -c "source /opt/portalgun/lib/install_sliver.sh && install_sliver" 2>&1 | tee -a "$LOG_FILE"
    sliver_rc=${PIPESTATUS[0]}
    set -e
    [ $sliver_rc -eq 0 ] && print_success "Sliver installed" \
        || print_warning "Sliver install non-fatal failure (see $LOG_FILE)"
else
    print_status "Sliver install SKIPPED (PORTALGUN_SKIP_SLIVER=1)"
fi

# ───────────────────────────────────────────────────────────────────
# Done!
# ───────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}INSTALLATION COMPLETE!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Installation finished: $(date)"
echo "Log file: $LOG_FILE"
echo ""
echo "Installed components:"
profile_summary "$PORTALGUN_PROFILE"
echo "  [+] Profile helpers: $(jq -r 'if (.helpers // [] | length)==0 then "none" else (.helpers|join(", ")) end' "$(profile_file "$PORTALGUN_PROFILE")")"
echo "  [+] Libraries: System libraries"
echo "  [+] Kali Tools: From apt repositories"
echo "  [+] GitHub Tools: Security tools in /opt/tools"
echo "  [+] Webserver: http://$IP:1337"
echo "  [+] BloodHound CE: http://$IP:1338"
echo "  [+] Firefox: profile restored from seed"
echo "  [+] portalgun: /usr/local/bin/portalgun (try: portalgun doctor)"
echo ""
echo "Next steps:"
echo "  1. Log out and back in so login-shell and group changes take effect"
echo "  2. Verify the profile: portalgun --profile $PORTALGUN_PROFILE profile verify"
echo "  3. Access tools server at http://$IP:1337"
echo ""

# Always export the install log for offline triage, regardless of debug mode.
if [ -f "$LOG_FILE" ]; then
    EXPORT_HELPER="$SCRIPT_DIR/lib/export_install_log.sh"
    [ -f "$EXPORT_HELPER" ] && sudo bash "$EXPORT_HELPER" "$LOG_FILE" || true
fi

# Run portalgun verify so the install summary ends with a hard pass/fail audit.
if command -v portalgun >/dev/null 2>&1; then
    echo
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}POST-INSTALL VERIFICATION${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    set +e
    sudo portalgun \
        --profile "$PORTALGUN_PROFILE" \
        --target-user "$PORTALGUN_TARGET_USER" \
        verify 2>&1 | tee -a "$LOG_FILE"

    VERIFY_RC=${PIPESTATUS[0]}
    set -e
else
    VERIFY_RC=1
    print_error "Portalgun verification command is unavailable"
fi

# Debug mode error summary
if [ "$DEBUG_MODE" = true ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}DEBUG SUMMARY${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Debug log saved to: $DEBUG_LOG"
    echo "Log size: $(du -h "$DEBUG_LOG" | cut -f1)"
    echo ""

    ERROR_COUNT=$(grep -ci "error\|failed\|fatal" "$DEBUG_LOG" 2>/dev/null || echo "0")
    WARNING_COUNT=$(grep -ci "warning\|warn" "$DEBUG_LOG" 2>/dev/null || echo "0")

    echo "Errors found: $ERROR_COUNT"
    echo "Warnings found: $WARNING_COUNT"

    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo ""
        echo "Error lines (first 20):"
        echo "───────────────────────────────────────────────────────────────────"
        grep -i "error\|failed\|fatal" "$DEBUG_LOG" 2>/dev/null | head -20
        echo "───────────────────────────────────────────────────────────────────"
    fi

    echo ""
    echo "To view full log: cat $DEBUG_LOG"
    echo "To search for errors: grep -i 'error\|failed' $DEBUG_LOG"
fi

echo "═══════════════════════════════════════════════════════════════════"

if [ "${VERIFY_RC:-1}" -ne 0 ]; then
    print_error "Installation completed, but post-install verification failed"
    exit "$VERIFY_RC"
fi

print_success "Installation and post-install verification completed successfully"
