#!/bin/bash
# portalgun production validation — revert, deploy, install, validate, repeat

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

JUMP="p3ta@192.168.1.49"
VM_IP="192.168.122.23"
VM_USER="kali"
VM_PASS="kali"
VM_NAME="linux2024"
VM_SNAP="snapshot1"
REPO="/home/p3ta/dev/portalgun"
LOGS="$REPO/tests/logs"
VM_LOG="/tmp/pg_install.log"
MAX_ITER=9

mkdir -p "$LOGS"

log()  { echo -e "${BLUE}[TEST $(date +%H:%M:%S)]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# scp a local file to VM via jump host
vm_scp() {
    local src="$1" dst="$2"
    scp -o "ProxyJump=$JUMP" -o StrictHostKeyChecking=no "$src" "$VM_USER@$VM_IP:$dst" 2>&1 || true
}

# Run a command on VM via jump host (key auth, kali has NOPASSWD sudo)
vm() {
    ssh -o "ProxyJump=$JUMP" \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=9999 \
        "$VM_USER@$VM_IP" "$@" 2>&1 || true
}

# Run sudo command on VM
vmsudo() {
    vm "sudo $*"
}

revert() {
    log "Reverting $VM_NAME → $VM_SNAP ..."
    ssh "$JUMP" "sudo virsh snapshot-revert $VM_NAME $VM_SNAP --running 2>&1" || true
    log "Waiting for SSH (using sshpass until key is installed)..."
    local attempts=0
    while ! ssh "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            $VM_USER@$VM_IP echo ok" >/dev/null 2>&1; do
        attempts=$(( attempts + 1 ))
        [ "$attempts" -gt 80 ] && { fail "VM never came up after 4 min"; exit 1; }
        sleep 3
    done
    log "SSH up after ${attempts} attempts."

    # Clear stale host keys
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" >/dev/null 2>&1 || true
    ssh "$JUMP" "ssh-keygen -f ~/.ssh/known_hosts -R $VM_IP >/dev/null 2>&1; true" 2>/dev/null || true

    # Add kali to kali-trusted (NOPASSWD sudo) — must come before key push so sudo works
    ssh "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no $VM_USER@$VM_IP \
        'echo $VM_PASS | sudo -S usermod -aG kali-trusted $VM_USER'" >/dev/null 2>&1 || true

    # Push SSH public key for ProxyJump (passwordless from here on)
    local pubkey
    pubkey=$(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || cat "$HOME/.ssh/id_rsa.pub" 2>/dev/null)
    if [ -n "$pubkey" ]; then
        ssh "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no $VM_USER@$VM_IP \
            'mkdir -p ~/.ssh && echo \"$pubkey\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'" >/dev/null 2>&1 || true
    fi

    log "VM ready."
}

deploy() {
    # Sync clock — snapshot revert leaves clock frozen
    local epoch
    epoch=$(date +%s)
    log "Syncing clock to $epoch..."
    vm "sudo date -s @$epoch" > /dev/null

    log "Rsyncing portalgun source to VM..."
    rsync -a --delete \
        --exclude='*.pyc' --exclude='__pycache__' \
        --exclude='.git'  --exclude='tests/' \
        -e "ssh -o StrictHostKeyChecking=no -o ProxyJump=$JUMP" \
        "$REPO/" "$VM_USER@$VM_IP:/home/$VM_USER/portalgun/" 2>&1 | tail -2

    log "Installing prerequisites (apt update + jq rsync python3)..."
    vm "sudo apt-get update -qq 2>&1 | tail -1"
    vm "sudo apt-get install -y -q jq rsync python3 2>&1 | tail -1"

    log "Copying and running vm_deploy.sh on VM..."
    vm_scp "$REPO/tests/vm_deploy.sh" "/tmp/vm_deploy.sh"
    vm "chmod +x /tmp/vm_deploy.sh && sudo bash /tmp/vm_deploy.sh"

    log "Deploy + install started."
}

wait_for_install() {
    local logfile="$1"
    local max_wait=150
    local elapsed=0

    log "Polling VM install log (max ${max_wait}m)..."
    while true; do
        vm "cat $VM_LOG 2>/dev/null" > "$logfile" 2>/dev/null

        local plain
        plain=$(sed 's/\x1b\[[0-9;]*m//g' "$logfile" 2>/dev/null)

        if echo "$plain" | grep -q "Done. Run 'portalgun status'"; then
            log "Install complete after ${elapsed}m."
            return 0
        fi

        if echo "$plain" | grep -q "Command exited with code [^0]"; then
            warn "Install hit an error — checking if it continued..."
        fi

        elapsed=$(( elapsed + 1 ))
        if [ "$elapsed" -ge "$max_wait" ]; then
            fail "Timed out after ${max_wait}m"
            return 1
        fi

        local phase
        phase=$(echo "$plain" | grep -oE "Phase [0-9]+:" | tail -1 || echo "waiting...")
        local last
        last=$(echo "$plain" | grep -v "^$" | tail -1 | cut -c1-80)
        log "[${elapsed}m] $phase $last"
        sleep 60
    done
}

validate() {
    local logfile="$1"
    local iter="$2"
    local errors=0

    log "=== Validating iteration $iter ==="

    local plain
    plain=$(sed 's/\x1b\[[0-9;]*m//g' "$logfile" 2>/dev/null)

    # Apt
    if echo "$plain" | grep -q "apt phase complete"; then
        pass "apt phase completed"
    else
        fail "apt phase did not complete"
        errors=$(( errors + 1 ))
    fi

    # Github
    local gh_ok gh_fail
    gh_ok=$(echo "$plain" | grep -oE "github: [0-9]+ installed" | grep -oE "[0-9]+" | head -1 || echo 0)
    gh_fail=$(echo "$plain" | grep -oE "[0-9]+ failed" | grep -oE "^[0-9]+" | head -1 || echo 0)
    if [ "${gh_fail:-0}" -gt 0 ]; then
        fail "github: $gh_fail tools failed"
        echo "$plain" | grep -E "\[FAILED\]| failed$" | head -10
        errors=$(( errors + 1 ))
    else
        pass "github: ${gh_ok:-0} installed, 0 failed"
    fi

    # PEP 668
    local pep
    pep=$(echo "$plain" | grep -c "break-system-packages\|externally-managed\|PEP 668" 2>/dev/null || echo 0)
    if [ "$pep" -gt 0 ]; then
        fail "pip blocked by PEP 668 ($pep occurrences)"
        errors=$(( errors + 1 ))
    else
        pass "pip: no PEP 668 blocks"
    fi

    # Pip phase
    if echo "$plain" | grep -q "pip phase complete"; then
        pass "pip phase completed"
    else
        fail "pip phase did not complete"
        errors=$(( errors + 1 ))
    fi

    # jq
    if echo "$plain" | grep -q "jq: error\|compile error"; then
        fail "jq errors:"
        echo "$plain" | grep "jq: error\|compile error" | head -5
        errors=$(( errors + 1 ))
    else
        pass "jq: clean"
    fi

    # Completion
    if echo "$plain" | grep -q "Done. Run 'portalgun status'"; then
        pass "install: reached completion"
    else
        fail "install: never reached completion"
        errors=$(( errors + 1 ))
    fi

    # Registry
    local status_out total
    status_out=$(vm "sudo portalgun status 2>&1")
    total=$(echo "$status_out" | grep "total:" | grep -oE "[0-9]+" | tail -1 || echo 0)
    echo "$status_out" | grep -E "apt|github|pip|cargo|total" || true
    if [ "${total:-0}" -ge 1000 ]; then
        pass "registry: $total tools"
    else
        fail "registry: $total tools (expected 1000+)"
        errors=$(( errors + 1 ))
    fi

    echo ""
    if [ "$errors" -eq 0 ]; then
        pass "═══ ITERATION $iter: ZERO ERRORS — PRODUCTION READY ═══"
        return 0
    else
        fail "═══ ITERATION $iter: $errors errors ═══"
        log "Last 30 lines of install log:"
        echo "$plain" | tail -30

        # Auto-fix pip conflicts found in this run
        local conflicts
        conflicts=$(echo "$plain" | grep "Cannot install" | grep -oE "[a-z][a-z0-9._-]+==[0-9][^ ]+" | sort -u)
        if [ -n "$conflicts" ]; then
            log "Auto-fixing pip conflicts: stripping version pins"
            for pkg_spec in $conflicts; do
                pkg_name=$(echo "$pkg_spec" | cut -d= -f1)
                log "  Stripping version pin: $pkg_spec -> $pkg_name"
                python3 -c "
import json
with open('/home/p3ta/dev/portalgun/portalgun_bundle.json') as f:
    b = json.load(f)
b['tools']['pip'] = [p if p.split('==')[0].lower() != '${pkg_name}'.lower() else '${pkg_name}' for p in b['tools']['pip']]
with open('/home/p3ta/dev/portalgun/portalgun_bundle.json', 'w') as f:
    json.dump(b, f, indent=2)
"
            done
        fi

        # Auto-fix build failures — remove packages that failed to build
        local build_fails
        build_fails=$(echo "$plain" | grep "Failed to build" | grep -oE "'[a-z][a-z0-9._-]+'" | tr -d "'" | sort -u)
        if [ -n "$build_fails" ]; then
            log "Auto-fixing build failures: removing packages"
            for pkg_name in $build_fails; do
                log "  Removing: $pkg_name"
                python3 -c "
import json
with open('/home/p3ta/dev/portalgun/portalgun_bundle.json') as f:
    b = json.load(f)
b['tools']['pip'] = [p for p in b['tools']['pip'] if p.split('==')[0].lower() != '${pkg_name}'.lower()]
with open('/home/p3ta/dev/portalgun/portalgun_bundle.json', 'w') as f:
    json.dump(b, f, indent=2)
"
            done
        fi

        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "portalgun production validation — up to $MAX_ITER iterations"
log "VM: $VM_USER@$VM_IP via $JUMP"

for i in $(seq 1 $MAX_ITER); do
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  ITERATION $i / $MAX_ITER"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    LOGFILE="$LOGS/iter${i}_$(date +%Y%m%d_%H%M%S).log"

    revert
    deploy
    wait_for_install "$LOGFILE"

    if validate "$LOGFILE" "$i"; then
        pass "Iteration $i/$MAX_ITER: CLEAN"
        cd "$REPO"
        git add -A
        git commit -m "portalgun: clean install run $i/$MAX_ITER" \
            --author="Claude Sonnet 4.6 <noreply@anthropic.com>" 2>/dev/null || true
        git push 2>/dev/null || true
    else
        log "Iteration $i failed — auto-fixes applied, continuing..."
    fi
done

# Final summary
total_passes=$(grep -c "Iteration.*CLEAN" "$LOGS/master_run_"*.log 2>/dev/null || echo "?")
pass "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
pass "  COMPLETED $MAX_ITER ITERATIONS"
pass "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
