#!/usr/bin/env bash
# portalgun Burp Suite Pro installer + license import + BApp preload
# Designed to work fully offline once initial download is complete.

BURP_DIR="${BURP_DIR:-/opt/portalgun/burpsuite}"
BURP_JAR="${BURP_JAR:-$BURP_DIR/BurpSuitePro.jar}"
BURP_LICENSE_DIR="${BURP_LICENSE_DIR:-$BURP_DIR/license-import}"
BURP_LICENSE_TEMPLATE="${BURP_LICENSE_TEMPLATE:-$BURP_LICENSE_DIR/prefs.xml}"
BURP_BAPPS_DIR="${BURP_BAPPS_DIR:-$BURP_DIR/bapps}"
BURP_BAPP_MANIFEST="${BURP_BAPP_MANIFEST:-$BURP_BAPPS_DIR/manifest.json}"
BURP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BURP_BAPP_CACHE_HELPER="${BURP_BAPP_CACHE_HELPER:-$BURP_LIB_DIR/cache_official_bapps.py}"
BURP_CDN="https://portswigger-cdn.net/burp/releases/download?product=pro&type=Jar"

_burp_log() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
_burp_ok()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
_burp_err() { printf '\033[0;31m[!]\033[0m %s\n' "$*" >&2; }

_burp_users() {
    # Print every account that should get a Burp config: root + every /home/*
    echo "root:/root"
    for h in /home/*; do
        [ -d "$h" ] || continue
        printf '%s:%s\n' "$(basename "$h")" "$h"
    done
}

ensure_java_21() {
    if command -v java >/dev/null 2>&1; then
        local ver
        ver=$(java -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1)
        [ "${ver:-0}" -ge 21 ] && return 0
    fi
    _burp_log "Installing openjdk-21-jre-headless"
    DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jre-headless \
        || { _burp_err "Failed to install Java 21"; return 1; }
}

download_burp_pro() {
    mkdir -p "$BURP_DIR"
    _burp_log "Downloading Burp Suite Pro JAR (this is ~700MB)"
    if curl -fL --retry 3 --connect-timeout 30 -o "$BURP_JAR.new" "$BURP_CDN"; then
        mv "$BURP_JAR.new" "$BURP_JAR"
        _burp_ok "Burp JAR: $BURP_JAR ($(du -h "$BURP_JAR" | cut -f1))"
    else
        _burp_err "Download failed"
        rm -f "$BURP_JAR.new"
        return 1
    fi
}

install_burp_launcher() {
    cat > /usr/local/bin/burpsuite-pro <<EOF
#!/usr/bin/env bash
# portalgun-managed Burp Suite Pro launcher
exec java -Djava.awt.headless=false -jar "$BURP_JAR" "\$@"
EOF
    chmod 755 /usr/local/bin/burpsuite-pro
    _burp_ok "Launcher → /usr/local/bin/burpsuite-pro"
}

apply_burp_license() {
    if [ ! -f "$BURP_LICENSE_TEMPLATE" ]; then
        _burp_log "No license file at $BURP_LICENSE_TEMPLATE — Burp will run unactivated."
        _burp_log "Drop a registered prefs.xml there (or run: portalgun import burp-license <path>)"
        return 0
    fi
    while IFS=: read -r user home; do
        local target="$home/.java/.userPrefs/burp"
        mkdir -p "$target/pro" "$target/community"
        cp "$BURP_LICENSE_TEMPLATE" "$target/prefs.xml"
        # Pro subdir gets an empty prefs.xml so Burp doesn't crash on first load
        if [ ! -f "$target/pro/prefs.xml" ]; then
            cat > "$target/pro/prefs.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE map SYSTEM "http://java.sun.com/dtd/preferences.dtd">
<map MAP_XML_VERSION="1.0"/>
EOF
        fi
        chown -R "$user:$user" "$home/.java" 2>/dev/null || true
        _burp_ok "License applied for $user ($target)"
    done < <(_burp_users)
}

cache_official_bapps() {
    local mode="${PORTALGUN_BAPP_CACHE_MODE:-official}"
    local require_cache="${PORTALGUN_REQUIRE_BAPP_CACHE:-0}"
    local workers="${PORTALGUN_BAPP_WORKERS:-4}"
    local cache_rc=0

    case "$mode" in
        official|metadata|off)
            ;;
        *)
            _burp_err "Unsupported PORTALGUN_BAPP_CACHE_MODE: $mode"
            return 64
            ;;
    esac

    if [ ! -f "$BURP_BAPP_CACHE_HELPER" ]; then
        _burp_err "Official BApp cache helper is missing: $BURP_BAPP_CACHE_HELPER"
        return 1
    fi

    mkdir -p "$BURP_BAPPS_DIR"

    _burp_log "BApp cache mode: $mode"

    if python3 "$BURP_BAPP_CACHE_HELPER" \
        --cache-dir "$BURP_BAPPS_DIR" \
        --mode "$mode" \
        --workers "$workers"
    then
        cache_rc=0
    else
        cache_rc=$?
    fi

    BURP_BAPP_CACHE_MODE_EFFECTIVE="$mode"

    case "$cache_rc" in
        0)
            case "$mode" in
                official)
                    BURP_BAPP_CACHE_STATUS="complete"
                    _burp_ok "Official BApp package cache completed"
                    ;;
                metadata)
                    BURP_BAPP_CACHE_STATUS="metadata"
                    _burp_ok "Official BApp metadata catalog completed"
                    ;;
                off)
                    BURP_BAPP_CACHE_STATUS="disabled"
                    _burp_log "Official BApp package cache disabled"
                    ;;
            esac

            return 0
            ;;

        2)
            BURP_BAPP_CACHE_STATUS="partial"

            if [ "$require_cache" = "1" ]; then
                _burp_err "Official BApp cache is incomplete and strict mode is enabled"
                return 1
            fi

            _burp_err "Official BApp cache is incomplete; continuing because it is optional"
            return 2
            ;;

        *)
            BURP_BAPP_CACHE_STATUS="failed"
            _burp_err "Official BApp cache failed"
            return 1
            ;;
    esac
}

stage_bapp_cache_for_users() {
    local package_dir="$BURP_BAPPS_DIR/packages"

    while IFS=: read -r user home; do
        local burp_home="$home/.BurpSuite"
        local cache_link="$burp_home/portalgun-bapp-cache"

        mkdir -p "$burp_home"

        if [ -L "$cache_link" ]; then
            rm -f "$cache_link"
        elif [ -e "$cache_link" ]; then
            _burp_err "Not replacing non-symlink path: $cache_link"
            continue
        fi

        if [ -d "$package_dir" ]; then
            ln -s "$package_dir" "$cache_link"
            chown -h "$user:$user" "$cache_link" 2>/dev/null || true
        fi

        chown "$user:$user" "$burp_home" 2>/dev/null || true
    done < <(_burp_users)

    _burp_ok "Official BApp cache exposed to users as ~/.BurpSuite/portalgun-bapp-cache"
}

register_burp() {
    local reg_dir="/var/lib/portalgun/registry/burp"
    local manifest="$BURP_BAPP_MANIFEST"
    local cache_mode="${BURP_BAPP_CACHE_MODE_EFFECTIVE:-${PORTALGUN_BAPP_CACHE_MODE:-official}}"
    local cache_status="${BURP_BAPP_CACHE_STATUS:-unknown}"
    local official_ids=0
    local packages_cached=0
    local cache_failures=0
    local license_applied=false

    mkdir -p "$reg_dir"

    if [ -f "$manifest" ]; then
        cache_mode=$(jq -r '.mode // "unknown"' "$manifest" 2>/dev/null || echo unknown)
        official_ids=$(jq -r '.summary.official_ids // 0' "$manifest" 2>/dev/null || echo 0)
        packages_cached=$(jq -r '.summary.packages_cached // 0' "$manifest" 2>/dev/null || echo 0)
        cache_failures=$(jq -r '.summary.failures // 0' "$manifest" 2>/dev/null || echo 0)
    fi

    [ -f "$BURP_LICENSE_TEMPLATE" ] && license_applied=true

    jq -n \
        --arg name "burp-pro" \
        --arg type "burp" \
        --arg jar "$BURP_JAR" \
        --arg launcher "/usr/local/bin/burpsuite-pro" \
        --arg bapps_dir "$BURP_BAPPS_DIR" \
        --arg bapp_manifest "$manifest" \
        --arg bapp_cache_mode "$cache_mode" \
        --arg bapp_cache_status "$cache_status" \
        --arg installed_at "$(date -Iseconds)" \
        --argjson license_applied "$license_applied" \
        --argjson official_ids "$official_ids" \
        --argjson packages_cached "$packages_cached" \
        --argjson cache_failures "$cache_failures" \
        '{
            name: $name,
            type: $type,
            jar: $jar,
            launcher: $launcher,
            license_applied: $license_applied,
            bapps_dir: $bapps_dir,
            bapp_manifest: $bapp_manifest,
            bapp_cache_mode: $bapp_cache_mode,
            bapp_cache_status: $bapp_cache_status,
            official_ids: $official_ids,
            packages_cached: $packages_cached,
            cache_failures: $cache_failures,
            installed_at: $installed_at
        }' > "$reg_dir/burp-pro.json"

    _burp_ok "Registered → $reg_dir/burp-pro.json"
}

install_burp_pro() {
    local bapp_rc=0

    mkdir -p "$BURP_DIR" "$BURP_LICENSE_DIR" "$BURP_BAPPS_DIR"

    ensure_java_21 || return 1
    download_burp_pro || return 1
    install_burp_launcher
    apply_burp_license

    if cache_official_bapps; then
        bapp_rc=0
    else
        bapp_rc=$?
    fi

    if [ "$bapp_rc" -eq 1 ] || [ "$bapp_rc" -ge 64 ]; then
        return "$bapp_rc"
    fi

    stage_bapp_cache_for_users
    register_burp

    _burp_ok "Burp Suite Pro install complete. Launch: burpsuite-pro"
}

update_burp_pro() {
    local bapp_rc=0

    _burp_log "Updating Burp Suite Pro"

    download_burp_pro || return 1
    install_burp_launcher
    apply_burp_license

    if cache_official_bapps; then
        bapp_rc=0
    else
        bapp_rc=$?
    fi

    if [ "$bapp_rc" -eq 1 ] || [ "$bapp_rc" -ge 64 ]; then
        return "$bapp_rc"
    fi

    stage_bapp_cache_for_users
    register_burp

    _burp_ok "Burp Suite Pro updated"
}

import_burp_license() {
    local src="$1"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        _burp_err "Usage: portalgun import burp-license <path-to-prefs.xml>"
        return 1
    fi
    mkdir -p "$BURP_LICENSE_DIR"
    cp "$src" "$BURP_LICENSE_TEMPLATE"
    chmod 600 "$BURP_LICENSE_TEMPLATE"
    _burp_ok "License blob staged at $BURP_LICENSE_TEMPLATE"
    apply_burp_license
}
