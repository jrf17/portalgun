#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Tools Documentation Server Launcher
# Starts the Flask-based tools server with config manager
# ═══════════════════════════════════════════════════════════════════

PORT="${1:-1337}"
DOC_DIR="/opt/tools-docs"
SERVER_SCRIPT="$DOC_DIR/tools_server.py"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

# Check if server script exists
if [ ! -f "$SERVER_SCRIPT" ]; then
    print_error "Server script not found at $SERVER_SCRIPT"
    print_status "Run setup_tools_server.sh first to deploy the server"
    exit 1
fi

# Check if Flask is installed
if ! python3 -c "import flask" 2>/dev/null; then
    print_status "Installing Flask..."
    pip3 install flask --quiet
fi

# Kill any existing server
pkill -f "tools_server.py" 2>/dev/null

# Get IP address
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "           ${GREEN}Kali Pentest Arsenal - Tools Server${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
print_success "Starting server on port $PORT"
echo ""
echo "  Local:   http://localhost:$PORT"
echo "  Network: http://$IP:$PORT"
echo ""
echo "  Features:"
echo "    - Tools documentation and search"
echo "    - Config Manager (Zsh, Zellij)"
echo "    - Custom hotkey editor"
echo ""
echo "Press Ctrl+C to stop"
echo ""

cd "$DOC_DIR"
python3 tools_server.py
