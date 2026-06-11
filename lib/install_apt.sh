#!/bin/bash
# portalgun apt installer

install_apt() {
    local pkg="$1"

    if [ -z "$pkg" ]; then
        print_error "Usage: portalgun install apt <package>"
        exit 1
    fi

    require_root install apt "$pkg"
    require_cmd apt-get apt-cache dpkg jq
    ensure_dirs

    print_status "Installing apt package: $pkg"

    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        print_error "Package not found in apt cache: $pkg"
        print_status "Try: sudo apt update"
        exit 1
    fi

    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        print_warning "$pkg is already installed — registering only"
    else
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"$PORTALGUN_LOG_DIR/apt.log" 2>&1; then
            print_error "apt install failed; see $PORTALGUN_LOG_DIR/apt.log"
            exit 1
        fi
        print_success "Installed $pkg"
    fi

    local version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "unknown")
    local json=$(jq -n \
        --arg name    "$pkg" \
        --arg package "$pkg" \
        --arg version "$version" \
        --arg added   "$(date -Iseconds)" \
        '{name:$name, type:"apt", package:$package, version:$version, status:"ok", added:$added}')
    registry_write apt "$pkg" "$json"
    print_success "Registered → $PORTALGUN_REGISTRY/apt/$pkg.json"

    source "$PORTALGUN_LIB/sync_web.sh"

    if [ "${PORTALGUN_SYNC_LEGACY_SCRIPTS:-0}" = "1" ]; then
        source "$PORTALGUN_LIB/sync_scripts.sh"
        sync_apt_to_script "$pkg"
    fi

    sync_web_manifest
}
