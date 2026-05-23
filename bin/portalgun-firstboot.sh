#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# portalgun first-boot hygiene
# Runs once on the FIRST boot of a cloned VM image. Regenerates any
# per-machine identity that needs to be unique so multiple clones
# don't collide on a network. Disables itself after running.
# ═══════════════════════════════════════════════════════════════════
set -e

SENTINEL=/var/lib/portalgun/firstboot-done
mkdir -p "$(dirname "$SENTINEL")"

if [ -f "$SENTINEL" ]; then
    exit 0
fi

echo "[portalgun-firstboot] regenerating per-machine identity..."

# 1. machine-id (used by systemd, dbus, NetworkManager DHCP client ID)
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

# 2. SSH host keys
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A >/dev/null
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true

# 3. Shell history (just in case the clone source had any)
rm -f /root/.bash_history /root/.zsh_history 2>/dev/null || true
for u in /home/*; do
    [ -d "$u" ] || continue
    rm -f "$u/.bash_history" "$u/.zsh_history" 2>/dev/null || true
done

# 4. Random seed (so urandom doesn't start identically on every clone)
if [ -e /var/lib/systemd/random-seed ]; then
    rm -f /var/lib/systemd/random-seed
fi

touch "$SENTINEL"
echo "[portalgun-firstboot] done"

# Disable ourselves so we don't run again
systemctl disable portalgun-firstboot.service >/dev/null 2>&1 || true
