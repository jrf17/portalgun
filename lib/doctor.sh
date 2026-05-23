#!/bin/bash
# portalgun doctor — health check for /opt/tools, registry, web manifest.
# Read-only diagnostics.

doctor_run() {
    require_cmd jq

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                    portalgun doctor"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # ─── 1. Registry ─────────────────────────────────────────────────
    local apt_count github_count
    apt_count=$(find "$PORTALGUN_REGISTRY/apt"    -name "*.json" 2>/dev/null | wc -l)
    github_count=$(find "$PORTALGUN_REGISTRY/github" -name "*.json" 2>/dev/null | wc -l)
    printf "Registry        %s\n" "$PORTALGUN_REGISTRY"
    printf "  apt:          %d tools\n" "$apt_count"
    printf "  github:       %d tools\n" "$github_count"

    # build_failed entries
    local build_failed
    build_failed=$(grep -l '"status": "build_failed"' "$PORTALGUN_REGISTRY"/github/*.json 2>/dev/null | wc -l)
    if [ "$build_failed" -gt 0 ]; then
        print_warning "  $build_failed registered github tools have status=build_failed"
        grep -l '"status": "build_failed"' "$PORTALGUN_REGISTRY"/github/*.json 2>/dev/null \
            | xargs -I{} jq -r '"    - " + .name + " (" + .repo + ")"' {} 2>/dev/null
    fi
    echo ""

    # ─── 2. /opt/tools audit ─────────────────────────────────────────
    if [ -d "$PORTALGUN_TOOLS_BASE" ]; then
        printf "Tool dirs       %s\n" "$PORTALGUN_TOOLS_BASE"
        python3 - "$PORTALGUN_TOOLS_BASE" <<'PYEOF'
import sys
from pathlib import Path
base = Path(sys.argv[1])
complete = no_files = empty = 0
for p in base.rglob("*"):
    if not p.is_dir(): continue
    if "source" in p.relative_to(base).parts: continue
    if (p / "source").is_dir():
        if any(x.is_file() for x in p.iterdir()):
            complete += 1
        else:
            no_files += 1
    else:
        subs = [x for x in p.iterdir() if x.is_dir() and x.name != "source"]
        files = [x for x in p.iterdir() if x.is_file()]
        if not subs and not files:
            empty += 1
print(f"  complete:     {complete}")
print(f"  source only:  {no_files}  (likely reference repos — usually fine)")
print(f"  empty:        {empty}")
PYEOF
    else
        print_warning "$PORTALGUN_TOOLS_BASE does not exist"
    fi
    echo ""

    # ─── 3. PATH symlinks ────────────────────────────────────────────
    local sym_count
    sym_count=$(/usr/bin/find /usr/local/bin -maxdepth 1 -type l -lname "/opt/tools/*" 2>/dev/null | wc -l)
    printf "PATH symlinks   /usr/local/bin → /opt/tools\n"
    printf "  total:        %d\n" "$sym_count"

    # Check for broken symlinks (target missing)
    local broken=0
    while read -r sym; do
        target=$(readlink "$sym")
        [ -e "$target" ] || broken=$((broken+1))
    done < <(/usr/bin/find /usr/local/bin -maxdepth 1 -type l -lname "/opt/tools/*" 2>/dev/null)
    if [ "$broken" -gt 0 ]; then
        print_warning "  $broken broken symlinks (target missing)"
    fi

    # Check for shadows of system commands (should be 0)
    local shadows=0
    while read -r sym; do
        bn=$(basename "$sym")
        if [ -e "/usr/bin/$bn" ] || [ -e "/bin/$bn" ] || [ -e "/usr/sbin/$bn" ] || [ -e "/sbin/$bn" ]; then
            shadows=$((shadows+1))
        fi
    done < <(/usr/bin/find /usr/local/bin -maxdepth 1 -type l -lname "/opt/tools/*" 2>/dev/null)
    if [ "$shadows" -gt 0 ]; then
        print_warning "  $shadows symlinks shadow system commands — run 'portalgun doctor --fix-shadows' to remove them"
    fi
    echo ""

    # ─── 4. Critical services ────────────────────────────────────────
    printf "Services\n"
    if systemctl is-active tools-server >/dev/null 2>&1; then
        printf "  tools-server:        ${GREEN}active${NC} (http://localhost:1337)\n"
    else
        printf "  tools-server:        ${YELLOW}inactive${NC}\n"
    fi
    if systemctl is-enabled portalgun-firstboot >/dev/null 2>&1; then
        if [ -f /var/lib/portalgun/firstboot-done ]; then
            printf "  portalgun-firstboot: ${BLUE}already run${NC} (sentinel exists)\n"
        else
            printf "  portalgun-firstboot: ${GREEN}enabled${NC} (will fire on next boot)\n"
        fi
    else
        printf "  portalgun-firstboot: ${YELLOW}not enabled${NC} — clones won't regenerate identity\n"
    fi
    # Use sudo for docker — kali isn't in docker group until first logout/login
    # after master_setup runs `usermod -aG docker`.
    if sudo -n docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^bloodhound-ce-bloodhound-1$"; then
        printf "  bloodhound:          ${GREEN}running${NC} (http://localhost:1338)\n"
    elif curl -s -o /dev/null -w "%{http_code}" http://localhost:1338 2>/dev/null | grep -q "^[0-9]"; then
        printf "  bloodhound:          ${GREEN}running${NC} (HTTP responding on :1338)\n"
    else
        printf "  bloodhound:          ${YELLOW}not running${NC}\n"
    fi
    echo ""

    # ─── 5. Web manifest freshness ───────────────────────────────────
    if [ -f "$PORTALGUN_WEB_DIR/portalgun_tools.json" ]; then
        local manifest_total
        manifest_total=$(jq -r '.totals.total' "$PORTALGUN_WEB_DIR/portalgun_tools.json" 2>/dev/null)
        local registry_total=$((apt_count + github_count))
        if [ "$manifest_total" != "$registry_total" ]; then
            print_warning "Web manifest reports $manifest_total tools but registry has $registry_total — drift. Re-run any portalgun install to refresh."
        fi
    fi

    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

doctor_fix_shadows() {
    require_root doctor --fix-shadows
    local removed=0
    while read -r sym; do
        bn=$(basename "$sym")
        if [ -e "/usr/bin/$bn" ] || [ -e "/bin/$bn" ] || [ -e "/usr/sbin/$bn" ] || [ -e "/sbin/$bn" ]; then
            rm -f "$sym"
            removed=$((removed+1))
            echo "removed shadow: $sym"
        fi
    done < <(/usr/bin/find /usr/local/bin -maxdepth 1 -type l -lname "/opt/tools/*" 2>/dev/null)
    print_success "Removed $removed shadow symlinks"
}

case "${1:-}" in
    --fix-shadows)
        doctor_fix_shadows
        ;;
    *)
        doctor_run
        ;;
esac
