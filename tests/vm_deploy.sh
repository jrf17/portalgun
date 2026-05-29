#!/bin/bash
# Runs ON the VM — sets up portalgun and starts the install
# Called via: scp to VM, then ssh to execute it

set -e
REPO="/home/kali/portalgun"
LOG="/tmp/pg_install.log"

echo "[vm_deploy] Setting up web dir..."
mkdir -p /opt/tools-docs
cp "$REPO/data/tools_server.py" /opt/tools-docs/
cp "$REPO/data/tools_readme.html" /opt/tools-docs/index.html
chown -R kali:kali /opt/tools-docs

echo "[vm_deploy] Installing portalgun..."
bash "$REPO/installers/portalgun_install.sh"

echo "[vm_deploy] Starting install all (logging to $LOG)..."
rm -f "$LOG"
nohup portalgun install all > "$LOG" 2>&1 &
echo "[vm_deploy] Install PID: $!"
echo "[vm_deploy] Done. Poll $LOG for progress."
