#!/usr/bin/env bash
# portalgun Sliver C2 installer + full armory preload
# Source: https://github.com/BishopFox/sliver

SLIVER_DIR="/opt/portalgun/sliver"
SLIVER_SERVER_BIN="/usr/local/bin/sliver-server"
SLIVER_CLIENT_BIN="/usr/local/bin/sliver-client"
SLIVER_INSTALL_URL="https://sliver.sh/install"
SLIVER_ARMORY_REQUIRED="${PORTALGUN_REQUIRE_SLIVER_ARMORY:-0}"

_sl_log() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
_sl_ok()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
_sl_err() { printf '\033[0;31m[!]\033[0m %s\n' "$*" >&2; }

_sl_users() {
    echo "root:/root"
    for h in /home/*; do
        [ -d "$h" ] || continue
        printf '%s:%s\n' "$(basename "$h")" "$h"
    done
}

ensure_sliver_installed() {
    if command -v sliver-server >/dev/null 2>&1 && command -v sliver-client >/dev/null 2>&1; then
        _sl_log "Sliver already installed: $(sliver-server version 2>&1 | head -1)"
        return 0
    fi
    _sl_log "Installing Sliver via official installer"
    curl -fL --retry 3 "$SLIVER_INSTALL_URL" | bash || {
        _sl_err "Installer failed; falling back to direct release download"
        sliver_direct_install || return 1
    }
}

sliver_direct_install() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) _sl_err "Unsupported arch: $arch"; return 1 ;;
    esac
    local server_url client_url
    server_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux"
    client_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux"
    [ "$arch" = "arm64" ] && {
        server_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux-arm64"
        client_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux-arm64"
    }
    curl -fL -o "$SLIVER_SERVER_BIN" "$server_url" && chmod +x "$SLIVER_SERVER_BIN"
    curl -fL -o "$SLIVER_CLIENT_BIN" "$client_url" && chmod +x "$SLIVER_CLIENT_BIN"
}

# Bundled offline path: if /opt/portalgun/data/sliver-armory/ exists (with
# armory.json + per-package tarballs), skip GitHub entirely. Otherwise fall
# back to the slow on-line `armory install <pkg>` loop (rate-limited).
stage_bundled_armory() {
    local bundle=""
    for candidate in /opt/portalgun/data/sliver-armory \
                     "$(dirname "${BASH_SOURCE[0]}")/../data/sliver-armory"; do
        [ -d "$candidate" ] && [ -f "$candidate/armory.json" ] && { bundle="$candidate"; break; }
    done
    [ -z "$bundle" ] && return 1

    _sl_log "Bundled armory cache found: $bundle"
    local ext_root=/root/.sliver-client/extensions
    local alias_root=/root/.sliver-client/aliases
    mkdir -p "$ext_root" "$alias_root"

    local ext_count=0 alias_count=0
    for pkg_dir in "$bundle"/*/; do
        [ -d "$pkg_dir" ] || continue
        local name
        name=$(basename "$pkg_dir")
        [ "$name" = "armory.json" ] && continue
        local tarball
        tarball=$(find "$pkg_dir" -maxdepth 1 -name "*.tar.gz" -o -name "*.tgz" | head -1)
        [ -z "$tarball" ] && continue
        # Aliases ship an alias.json; extensions ship an extension.json. Route
        # each package to the correct dir so sliver picks it up. Tar entries
        # may be prefixed with ./ — accept both.
        local kind="extensions"
        if tar tzf "$tarball" 2>/dev/null | grep -qE '(^|/)alias\.json$'; then
            kind="aliases"
        fi
        local dest
        if [ "$kind" = "aliases" ]; then
            dest="$alias_root/$name"
        else
            dest="$ext_root/$name"
        fi
        mkdir -p "$dest"
        if tar xzf "$tarball" -C "$dest" 2>/dev/null; then
            [ "$kind" = "aliases" ] && alias_count=$((alias_count + 1)) || ext_count=$((ext_count + 1))
        fi
    done
    _sl_ok "Staged $ext_count extensions + $alias_count aliases from bundle"
    return 0
}

# Sliver's `armory` CLI does NOT support `install all`. Need to:
#   1. Run `armory list` to enumerate every package (~200+)
#   2. Generate an rc file with one `armory install <pkg>` per line
#   3. Execute that rc against sliver-server
preinstall_sliver_armory() {
    if stage_bundled_armory; then
        _sl_ok "Armory installed offline from bundle"
        return 0
    fi

    _sl_err         "No bundled Sliver armory cache was found under data/sliver-armory"

    _sl_err         "Full online preload is disabled because the unauthenticated "         "GitHub API limit cannot support the complete armory catalog"

    if [ "${PORTALGUN_REQUIRE_SLIVER_ARMORY:-0}" = "1" ]; then
        _sl_err             "Sliver armory is required by PORTALGUN_REQUIRE_SLIVER_ARMORY=1"
        return 1
    fi

    _sl_log         "Continuing without optional Sliver aliases and extensions"

    return 2
}

# Copy root's sliver-client state (configs, extensions, armory cache) out to
# every user's home so non-root sliver-client users get the same offline-ready
# set without re-downloading.
stage_armory_for_users() {
    [ -d /root/.sliver-client ] || return 0
    while IFS=: read -r user home; do
        [ "$user" = "root" ] && continue
        mkdir -p "$home/.sliver-client"
        for sub in extensions aliases armories configs; do
            [ -d "/root/.sliver-client/$sub" ] || continue
            mkdir -p "$home/.sliver-client/$sub"
            cp -ru "/root/.sliver-client/$sub/." "$home/.sliver-client/$sub/" 2>/dev/null || true
        done
        chown -R "$user:$user" "$home/.sliver-client" 2>/dev/null || true
    done < <(_sl_users)
    _sl_ok "Armory + extensions staged for every user"
}

register_sliver() {
    local armory_rc="${1:-2}"
    local reg_dir="/var/lib/portalgun/registry/sliver"
    local server_path
    local client_path
    local armory_status

    server_path=$(command -v sliver-server 2>/dev/null || true)
    client_path=$(command -v sliver-client 2>/dev/null || true)

    case "$armory_rc" in
        0)
            armory_status="staged"
            ;;
        1)
            armory_status="required-failed"
            ;;
        *)
            armory_status="optional-not-staged"
            ;;
    esac

    mkdir -p "$reg_dir"

    jq -n         --arg server "$server_path"         --arg client "$client_path"         --arg armory_dir "/root/.sliver-client/armories"         --arg armory_status "$armory_status"         --arg installed_at "$(date -Iseconds)"         '{
            name: "sliver",
            type: "sliver",
            server: $server,
            client: $client,
            armory_dir: $armory_dir,
            armory_status: $armory_status,
            installed_at: $installed_at
        }' > "$reg_dir/sliver.json"

    _sl_ok "Registered → $reg_dir/sliver.json"
}

install_sliver() {
    local armory_rc=0

    mkdir -p "$SLIVER_DIR" /var/log/portalgun

    ensure_sliver_installed || return 1

    preinstall_sliver_armory || armory_rc=$?

    stage_armory_for_users
    register_sliver "$armory_rc"

    if [ "$armory_rc" -eq 1 ]; then
        return 1
    fi

    if [ "$armory_rc" -eq 2 ]; then
        _sl_log             "Sliver installed without the optional offline armory cache"
    fi

    _sl_ok         "Sliver install complete. Server: sliver-server | Client: sliver-client"

    return 0
}

update_sliver() {
    local armory_rc=0

    _sl_log "Updating Sliver"

    sliver_direct_install || return 1

    preinstall_sliver_armory || armory_rc=$?

    stage_armory_for_users
    register_sliver "$armory_rc"

    if [ "$armory_rc" -eq 1 ]; then
        return 1
    fi

    _sl_ok "Sliver updated"

    return 0
}
