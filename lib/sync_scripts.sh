#!/bin/bash
# portalgun → v1 scripts sync
# Optional repository-maintenance compatibility layer.
#
# Runtime installs must not modify the Portalgun source checkout. Set
# PORTALGUN_SYNC_LEGACY_SCRIPTS=1 only during an intentional repository
# maintenance operation.

PORTALGUN_MARK_START="# PORTALGUN_MANAGED_START — do not hand-edit between these markers"
PORTALGUN_MARK_END="# PORTALGUN_MANAGED_END"

_portalgun_legacy_script_sync_enabled() {
    [ "${PORTALGUN_SYNC_LEGACY_SCRIPTS:-0}" = "1" ]
}

sync_apt_to_script() {
    local pkg="$1"
    local script="$PORTALGUN_REPO_DIR/data/installable_packages.txt"

    _portalgun_legacy_script_sync_enabled || return 0

    if [ ! -f "$script" ]; then
        print_warning "v1 script not found: $script (apt-to-script sync skipped)"
        return 0
    fi

    if grep -qE "^${pkg}$" "$script"; then
        return 0
    fi

    if ! grep -qF "$PORTALGUN_MARK_START" "$script"; then
        printf '\n%s\n%s\n' "$PORTALGUN_MARK_START" "$PORTALGUN_MARK_END" >> "$script"
    fi

    # Insert before the END marker using python (avoids sed escaping pitfalls)
    python3 - "$script" "$pkg" <<'PYEOF'
import sys
path, pkg = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    if 'PORTALGUN_MANAGED_END' in line:
        lines.insert(i, pkg + '\n')
        break
with open(path, 'w') as f:
    f.writelines(lines)
PYEOF
    print_success "Appended '$pkg' → $script"
}

sync_github_to_script() {
    local id_name="$1"
    local script="$PORTALGUN_REPO_DIR/installers/install_github_tools.sh"

    _portalgun_legacy_script_sync_enabled || return 0

    if [ ! -f "$script" ]; then
        print_warning "v1 script not found: $script (github-to-script sync skipped)"
        return 0
    fi

    local json_path="$PORTALGUN_REGISTRY/github/$id_name.json"
    [ ! -f "$json_path" ] && return 0

    python3 "$PORTALGUN_LIB/sync_github.py" "$script" "$json_path" \
        && print_success "Appended tool entry → $script" \
        || print_warning "Failed to sync github entry to $script"
}
