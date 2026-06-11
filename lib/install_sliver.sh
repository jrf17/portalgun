#!/usr/bin/env bash
# Portalgun Sliver C2 provisioning.
# Source: https://github.com/BishopFox/sliver

SLIVER_DIR="${PORTALGUN_SLIVER_DIR:-/opt/portalgun/sliver}"
SLIVER_SERVER_ROOT="${PORTALGUN_SLIVER_SERVER_ROOT:-$SLIVER_DIR/server}"
SLIVER_ARMORY_CACHE="${PORTALGUN_SLIVER_ARMORY_CACHE:-$SLIVER_DIR/armory-cache}"
SLIVER_INSTALL_URL="https://sliver.sh/install"
SLIVER_SERVER_BIN="/usr/local/bin/sliver-server"
SLIVER_CLIENT_BIN="/usr/local/bin/sliver-client"
SLIVER_CACHE_HELPER="${PORTALGUN_SLIVER_CACHE_HELPER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache_sliver_armory.py}"
SLIVER_REGISTRY_ROOT="${PORTALGUN_SLIVER_REGISTRY_ROOT:-/var/lib/portalgun/registry/sliver}"
SLIVER_OPERATOR_NAME="${PORTALGUN_SLIVER_OPERATOR_NAME:-portalgun-local}"
SLIVER_OPERATOR_HOST="${PORTALGUN_SLIVER_OPERATOR_HOST:-127.0.0.1}"
SLIVER_OPERATOR_PORT="${PORTALGUN_SLIVER_OPERATOR_PORT:-31337}"

SLIVER_TARGET_USER_RESOLVED=""
SLIVER_TARGET_UID_RESOLVED=""
SLIVER_TARGET_GROUP_RESOLVED=""
SLIVER_TARGET_HOME_RESOLVED=""
SLIVER_CLIENT_ROOT_RESOLVED=""
SLIVER_OPERATOR_CONFIG_RESOLVED=""
SLIVER_ARMORY_MODE_RESOLVED=""
SLIVER_ARMORY_SUMMARY_JSON=""

_sl_log() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
_sl_ok()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
_sl_err() { printf '\033[0;31m[!]\033[0m %s\n' "$*" >&2; }

resolve_sliver_target() {
    local user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-}}"
    local passwd_entry
    local passwd_name
    local passwd_uid
    local passwd_gid
    local passwd_home
    local group_name

    if [ -z "$user" ]; then
        user=$(id -un)
    fi

    passwd_entry=$(getent passwd "$user") || {
        _sl_err "Invalid Sliver target user: $user"
        return 1
    }

    IFS=: read -r \
        passwd_name _ passwd_uid passwd_gid _ passwd_home _ \
        <<< "$passwd_entry"

    if [ "$passwd_name" != "$user" ] ||
        [ -z "$passwd_uid" ] ||
        [ -z "$passwd_gid" ] ||
        [ -z "$passwd_home" ] ||
        [ ! -d "$passwd_home" ]
    then
        _sl_err "Invalid passwd entry for Sliver target user: $user"
        return 1
    fi

    group_name=$(getent group "$passwd_gid" | cut -d: -f1)

    if [ -z "$group_name" ]; then
        _sl_err "Unable to resolve primary group for Sliver user: $user"
        return 1
    fi

    SLIVER_TARGET_USER_RESOLVED="$user"
    SLIVER_TARGET_UID_RESOLVED="$passwd_uid"
    SLIVER_TARGET_GROUP_RESOLVED="$group_name"
    SLIVER_TARGET_HOME_RESOLVED="$passwd_home"
    SLIVER_CLIENT_ROOT_RESOLVED="$passwd_home/.sliver-client"
    SLIVER_OPERATOR_CONFIG_RESOLVED="$SLIVER_CLIENT_ROOT_RESOLVED/configs/${SLIVER_OPERATOR_NAME}_${SLIVER_OPERATOR_HOST}.cfg"

    return 0
}

resolve_sliver_armory_mode() {
    local mode="${PORTALGUN_SLIVER_ARMORY_MODE:-official}"
    local legacy="${PORTALGUN_REQUIRE_SLIVER_ARMORY:-0}"

    case "$legacy" in
        0|"")
            ;;
        1)
            if [ "$mode" = "off" ]; then
                _sl_err "PORTALGUN_REQUIRE_SLIVER_ARMORY=1 conflicts with PORTALGUN_SLIVER_ARMORY_MODE=off"
                return 1
            fi
            mode="official"
            ;;
        *)
            _sl_err "Invalid PORTALGUN_REQUIRE_SLIVER_ARMORY value: $legacy"
            return 1
            ;;
    esac

    case "$mode" in
        official|off)
            SLIVER_ARMORY_MODE_RESOLVED="$mode"
            ;;
        *)
            _sl_err "Invalid PORTALGUN_SLIVER_ARMORY_MODE: $mode"
            return 1
            ;;
    esac

    return 0
}

_sl_run_as_target() {
    local current_uid
    current_uid=$(id -u)

    if [ "$current_uid" = "$SLIVER_TARGET_UID_RESOLVED" ]; then
        env \
            HOME="$SLIVER_TARGET_HOME_RESOLVED" \
            USER="$SLIVER_TARGET_USER_RESOLVED" \
            LOGNAME="$SLIVER_TARGET_USER_RESOLVED" \
            SLIVER_ROOT_DIR="$SLIVER_SERVER_ROOT" \
            SLIVER_CLIENT_ROOT_DIR="$SLIVER_CLIENT_ROOT_RESOLVED" \
            "$@"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        _sl_err "sudo is required to run Sliver as $SLIVER_TARGET_USER_RESOLVED"
        return 1
    fi

    sudo -u "$SLIVER_TARGET_USER_RESOLVED" -- env \
        HOME="$SLIVER_TARGET_HOME_RESOLVED" \
        USER="$SLIVER_TARGET_USER_RESOLVED" \
        LOGNAME="$SLIVER_TARGET_USER_RESOLVED" \
        SLIVER_ROOT_DIR="$SLIVER_SERVER_ROOT" \
        SLIVER_CLIENT_ROOT_DIR="$SLIVER_CLIENT_ROOT_RESOLVED" \
        "$@"
}

_sl_chown_target() {
    [ "${PORTALGUN_SLIVER_TEST_SKIP_CHOWN:-0}" = "1" ] && return 0

    chown "$SLIVER_TARGET_USER_RESOLVED:$SLIVER_TARGET_GROUP_RESOLVED" "$@"
}

_sl_chown_target_recursive() {
    local root="$1"

    [ "${PORTALGUN_SLIVER_TEST_SKIP_CHOWN:-0}" = "1" ] && return 0

    chown "$SLIVER_TARGET_USER_RESOLVED:$SLIVER_TARGET_GROUP_RESOLVED" "$root"

    find "$root" -xdev -mindepth 1 ! -type l \
        -exec chown "$SLIVER_TARGET_USER_RESOLVED:$SLIVER_TARGET_GROUP_RESOLVED" {} +

    find "$root" -xdev -mindepth 1 -type l \
        -exec chown -h "$SLIVER_TARGET_USER_RESOLVED:$SLIVER_TARGET_GROUP_RESOLVED" {} +
}

_sl_command_version() {
    local command_path="$1"
    local output

    output=$("$command_path" version 2>&1 || true)
    printf '%s\n' "$output" | sed -n '1p'
}

_sl_package_version() {
    dpkg-query -W -f='${Version}' sliver 2>/dev/null || true
}

ensure_sliver_installed() {
    local server_path
    local client_path
    local command_version
    local package_version

    server_path=$(command -v sliver-server 2>/dev/null || true)
    client_path=$(command -v sliver-client 2>/dev/null || true)

    if [ -n "$server_path" ] &&
        [ -x "$server_path" ] &&
        [ -n "$client_path" ] &&
        [ -x "$client_path" ]
    then
        command_version=$(_sl_command_version "$server_path")
        package_version=$(_sl_package_version)

        _sl_log "Sliver binaries already installed"
        _sl_log "Server: $server_path"
        _sl_log "Client: $client_path"
        _sl_log "Command version: ${command_version:-unknown}"

        if [ -n "$package_version" ]; then
            _sl_log "Package version: $package_version"
        fi

        return 0
    fi

    _sl_log "Installing Sliver via the official installer"

    local installer
    installer=$(mktemp /tmp/portalgun-sliver-installer.XXXXXX)

    if curl -fL --retry 3 --retry-delay 2 \
        "$SLIVER_INSTALL_URL" -o "$installer" &&
        bash "$installer"
    then
        rm -f "$installer"
    else
        rm -f "$installer"
        _sl_err "Official installer failed; using direct release binaries"
        sliver_direct_install || return 1
    fi

    server_path=$(command -v sliver-server 2>/dev/null || true)
    client_path=$(command -v sliver-client 2>/dev/null || true)

    if [ -z "$server_path" ] ||
        [ ! -x "$server_path" ] ||
        [ -z "$client_path" ] ||
        [ ! -x "$client_path" ]
    then
        _sl_err "Sliver binaries are not executable after installation"
        return 1
    fi

    return 0
}

sliver_direct_install() {
    local architecture
    local server_url
    local client_url
    local server_temp
    local client_temp

    architecture=$(uname -m)

    case "$architecture" in
        x86_64)
            server_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux"
            client_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux"
            ;;
        aarch64|arm64)
            server_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux-arm64"
            client_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux-arm64"
            ;;
        *)
            _sl_err "Unsupported Sliver architecture: $architecture"
            return 1
            ;;
    esac

    server_temp=$(mktemp /tmp/sliver-server.XXXXXX)
    client_temp=$(mktemp /tmp/sliver-client.XXXXXX)

    if ! curl -fL --retry 3 --retry-delay 2 \
        "$server_url" -o "$server_temp"
    then
        rm -f "$server_temp" "$client_temp"
        return 1
    fi

    if ! curl -fL --retry 3 --retry-delay 2 \
        "$client_url" -o "$client_temp"
    then
        rm -f "$server_temp" "$client_temp"
        return 1
    fi

    install -m 0755 "$server_temp" "$SLIVER_SERVER_BIN"
    install -m 0755 "$client_temp" "$SLIVER_CLIENT_BIN"
    rm -f "$server_temp" "$client_temp"

    return 0
}

ensure_sliver_directories() {
    install -d -m 0755 "$SLIVER_DIR"
    install -d -m 0700 "$SLIVER_SERVER_ROOT"
    install -d -m 0700 "$SLIVER_CLIENT_ROOT_RESOLVED"
    install -d -m 0700 "$SLIVER_CLIENT_ROOT_RESOLVED/configs"

    _sl_chown_target "$SLIVER_SERVER_ROOT"
    _sl_chown_target_recursive "$SLIVER_CLIENT_ROOT_RESOLVED"
}

sliver_assets_valid() {
    [ -s "$SLIVER_SERVER_ROOT/configs/server.yaml" ] &&
        [ -s "$SLIVER_SERVER_ROOT/configs/database.yaml" ] &&
        [ -s "$SLIVER_SERVER_ROOT/sliver.db" ] &&
        [ -s "$SLIVER_SERVER_ROOT/nouns.txt" ] &&
        [ -s "$SLIVER_SERVER_ROOT/adjectives.txt" ] &&
        [ -x "$SLIVER_SERVER_ROOT/go/bin/go" ] &&
        [ -x "$SLIVER_SERVER_ROOT/zig/zig" ]
}

initialize_sliver_assets() {
    local server_path
    local unpack_output
    local unpack_rc=0

    server_path=$(command -v sliver-server 2>/dev/null || true)

    if [ -z "$server_path" ] || [ ! -x "$server_path" ]; then
        _sl_err "sliver-server is unavailable for asset initialization"
        return 1
    fi

    if sliver_assets_valid; then
        _sl_ok "Sliver server assets already initialized"
        return 0
    fi

    _sl_log "Initializing Sliver server assets"

    unpack_output=$(mktemp /tmp/portalgun-sliver-unpack.XXXXXX)

    _sl_run_as_target \
        "$server_path" unpack --force \
        > "$unpack_output" 2>&1 || unpack_rc=$?

    if [ "$unpack_rc" -ne 0 ]; then
        _sl_err "Sliver asset initialization failed with status $unpack_rc"
        sed -n '1,80p' "$unpack_output" >&2
        rm -f "$unpack_output"
        return 1
    fi

    rm -f "$unpack_output"

    if ! sliver_assets_valid; then
        _sl_err "Sliver asset initialization returned success but required assets are missing"
        return 1
    fi

    _sl_chown_target_recursive "$SLIVER_SERVER_ROOT"
    _sl_ok "Sliver server assets initialized"

    return 0
}

sliver_operator_config_valid() {
    local config_path="${1:-$SLIVER_OPERATOR_CONFIG_RESOLVED}"

    [ -s "$config_path" ] || return 1

    python3 - \
        "$config_path" \
        "$SLIVER_OPERATOR_NAME" \
        "$SLIVER_OPERATOR_HOST" \
        "$SLIVER_OPERATOR_PORT" << 'PY' >/dev/null
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_operator = sys.argv[2]
expected_host = sys.argv[3]
expected_port = int(sys.argv[4])

try:
    value = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(value, dict):
    raise SystemExit(1)

required_strings = (
    "operator",
    "lhost",
    "ca_certificate",
    "certificate",
    "private_key",
    "token",
)

if any(
    not isinstance(value.get(key), str) or not value[key]
    for key in required_strings
):
    raise SystemExit(1)

if value["operator"] != expected_operator:
    raise SystemExit(1)

if value["lhost"] != expected_host:
    raise SystemExit(1)

if value.get("lport") != expected_port:
    raise SystemExit(1)
PY
}

ensure_sliver_operator_config() {
    local server_path
    local client_path
    local temporary_dir
    local generated_config
    local operator_output
    local import_output
    local operator_rc=0
    local import_rc=0

    server_path=$(command -v sliver-server 2>/dev/null || true)
    client_path=$(command -v sliver-client 2>/dev/null || true)

    if [ -z "$server_path" ] ||
        [ ! -x "$server_path" ] ||
        [ -z "$client_path" ] ||
        [ ! -x "$client_path" ]
    then
        _sl_err "Sliver binaries are unavailable for operator provisioning"
        return 1
    fi

    if sliver_operator_config_valid "$SLIVER_OPERATOR_CONFIG_RESOLVED"; then
        chmod 0600 "$SLIVER_OPERATOR_CONFIG_RESOLVED"
        _sl_chown_target "$SLIVER_OPERATOR_CONFIG_RESOLVED"
        _sl_ok "Sliver operator configuration already valid"
        return 0
    fi

    _sl_log "Generating Portalgun-owned loopback Sliver operator configuration"

    rm -f "$SLIVER_OPERATOR_CONFIG_RESOLVED"

    temporary_dir=$(mktemp -d /tmp/portalgun-sliver-operator.XXXXXX)
    generated_config="$temporary_dir/portalgun-local.cfg"
    operator_output="$temporary_dir/operator.out"
    import_output="$temporary_dir/import.out"

    _sl_chown_target_recursive "$temporary_dir"

    _sl_run_as_target \
        "$server_path" operator \
        --name "$SLIVER_OPERATOR_NAME" \
        --lhost "$SLIVER_OPERATOR_HOST" \
        --lport "$SLIVER_OPERATOR_PORT" \
        --permissions all \
        --save "$generated_config" \
        > "$operator_output" 2>&1 || operator_rc=$?

    if [ "$operator_rc" -ne 0 ] ||
        ! sliver_operator_config_valid "$generated_config"
    then
        _sl_err "Sliver operator generation failed"
        sed -n '1,80p' "$operator_output" >&2
        rm -rf "$temporary_dir"
        return 1
    fi

    _sl_run_as_target \
        "$client_path" import "$generated_config" \
        > "$import_output" 2>&1 || import_rc=$?

    if [ "$import_rc" -ne 0 ] ||
        ! sliver_operator_config_valid "$SLIVER_OPERATOR_CONFIG_RESOLVED"
    then
        _sl_err "Sliver client configuration import failed"
        sed -n '1,80p' "$import_output" >&2
        rm -rf "$temporary_dir"
        return 1
    fi

    chmod 0600 "$SLIVER_OPERATOR_CONFIG_RESOLVED"
    _sl_chown_target_recursive "$SLIVER_CLIENT_ROOT_RESOLVED"
    rm -rf "$temporary_dir"

    _sl_ok "Sliver operator configuration created for $SLIVER_TARGET_USER_RESOLVED"

    return 0
}

resolve_sliver_preseed() {
    local explicit="${PORTALGUN_SLIVER_ARMORY_PRESEED:-}"
    local candidate

    if [ -n "$explicit" ]; then
        if [ -f "$explicit/armory.json" ] &&
            [ -f "$explicit/armory.minisig" ]
        then
            printf '%s\n' "$explicit"
            return 0
        fi

        _sl_err "Invalid Sliver Armory preseed: $explicit"
        return 1
    fi

    for candidate in \
        /opt/portalgun/data/sliver-armory \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data/sliver-armory"
    do
        if [ -f "$candidate/armory.json" ] &&
            [ -f "$candidate/armory.minisig" ]
        then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 2
}

cache_sliver_armory() {
    local preseed=""
    local preseed_rc=0
    local workers="${PORTALGUN_SLIVER_ARMORY_WORKERS:-4}"
    local command=()
    local summary

    if [ ! -x "$SLIVER_CACHE_HELPER" ]; then
        _sl_err "Sliver Armory cache helper is missing: $SLIVER_CACHE_HELPER"
        return 1
    fi

    if ! command -v minisign >/dev/null 2>&1; then
        _sl_err "minisign is required for Sliver Armory verification"
        return 1
    fi

    preseed=$(resolve_sliver_preseed) || preseed_rc=$?

    if [ "$preseed_rc" -eq 1 ]; then
        return 1
    fi

    command=(
        python3
        "$SLIVER_CACHE_HELPER"
        sync
        --cache-root "$SLIVER_ARMORY_CACHE"
        --workers "$workers"
        --json
    )

    if [ -n "$preseed" ]; then
        command+=(--preseed "$preseed")
        _sl_log "Synchronizing Sliver Armory from signed preseed: $preseed"
    else
        _sl_log "Synchronizing complete signed official Sliver Armory cache"
    fi

    if ! summary=$("${command[@]}"); then
        _sl_err "Sliver Armory cache synchronization failed"
        return 1
    fi

    if ! jq -e '
        .status == "complete" and
        .cached_extension_count == .expected_extension_count and
        .cached_alias_count == .expected_alias_count
    ' <<< "$summary" >/dev/null
    then
        _sl_err "Sliver Armory cache helper returned an incomplete summary"
        return 1
    fi

    SLIVER_ARMORY_SUMMARY_JSON="$summary"

    _sl_ok "Sliver Armory cache complete: $(jq -r '
        "\(.cached_extension_count)/\(.expected_extension_count) extensions, " +
        "\(.cached_alias_count)/\(.expected_alias_count) aliases"
    ' <<< "$summary")"

    return 0
}

validate_sliver_armory_cache() {
    local summary

    if ! summary=$(
        python3 "$SLIVER_CACHE_HELPER" validate \
            --cache-root "$SLIVER_ARMORY_CACHE" \
            --json
    )
    then
        return 1
    fi

    if ! jq -e '
        .status == "complete" and
        .cached_extension_count == .expected_extension_count and
        .cached_alias_count == .expected_alias_count
    ' <<< "$summary" >/dev/null
    then
        return 1
    fi

    SLIVER_ARMORY_SUMMARY_JSON="$summary"
    return 0
}

stage_sliver_armory_for_target() {
    local kind
    local source
    local destination
    local resolved_source
    local resolved_destination

    for kind in extensions aliases; do
        source="$SLIVER_ARMORY_CACHE/$kind"
        destination="$SLIVER_CLIENT_ROOT_RESOLVED/$kind"

        if [ ! -d "$source" ]; then
            _sl_err "Validated Sliver cache is missing $kind"
            return 1
        fi

        resolved_source=$(readlink -f "$source")

        if [ -L "$destination" ]; then
            resolved_destination=$(readlink -f "$destination" || true)

            if [ "$resolved_destination" = "$resolved_source" ]; then
                _sl_chown_target -h "$destination"
                continue
            fi

            _sl_err "Refusing to replace unrelated Sliver symlink: $destination"
            return 1
        fi

        if [ -d "$destination" ]; then
            if [ -n "$(find "$destination" -mindepth 1 -print -quit 2>/dev/null)" ]; then
                _sl_err "Refusing to replace non-empty Sliver directory: $destination"
                return 1
            fi

            rmdir "$destination"
        elif [ -e "$destination" ]; then
            _sl_err "Refusing to replace unexpected Sliver path: $destination"
            return 1
        fi

        ln -s "$source" "$destination"
        _sl_chown_target -h "$destination"
    done

    if [[ "$(readlink -f "$SLIVER_CLIENT_ROOT_RESOLVED/extensions")" != \
        "$(readlink -f "$SLIVER_ARMORY_CACHE/extensions")" ]] ||
        [[ "$(readlink -f "$SLIVER_CLIENT_ROOT_RESOLVED/aliases")" != \
        "$(readlink -f "$SLIVER_ARMORY_CACHE/aliases")" ]]
    then
        _sl_err "Sliver Armory target-user staging validation failed"
        return 1
    fi

    _sl_ok "Sliver Armory staged for $SLIVER_TARGET_USER_RESOLVED"

    return 0
}

target_sliver_state_owned() {
    local unexpected

    unexpected=$(
        find "$SLIVER_CLIENT_ROOT_RESOLVED" -xdev \
            ! -user "$SLIVER_TARGET_UID_RESOLVED" \
            -print -quit 2>/dev/null
    )

    [ -z "$unexpected" ]
}

invalidate_sliver_registry() {
    rm -f "$SLIVER_REGISTRY_ROOT/sliver.json"
}

register_sliver() {
    local server_path
    local client_path
    local package_version
    local server_command_version
    local client_command_version
    local armory_status
    local armory_manifest=""
    local extensions_expected=0
    local extensions_staged=0
    local aliases_expected=0
    local aliases_staged=0
    local temporary

    server_path=$(command -v sliver-server 2>/dev/null || true)
    client_path=$(command -v sliver-client 2>/dev/null || true)
    package_version=$(_sl_package_version)
    server_command_version=$(_sl_command_version "$server_path")
    client_command_version=$(_sl_command_version "$client_path")

    if [ "$SLIVER_ARMORY_MODE_RESOLVED" = "official" ]; then
        armory_status="complete"
        armory_manifest="$SLIVER_ARMORY_CACHE/manifest.json"
        extensions_expected=$(jq -r '.expected_extension_count' <<< "$SLIVER_ARMORY_SUMMARY_JSON")
        extensions_staged=$(jq -r '.cached_extension_count' <<< "$SLIVER_ARMORY_SUMMARY_JSON")
        aliases_expected=$(jq -r '.expected_alias_count' <<< "$SLIVER_ARMORY_SUMMARY_JSON")
        aliases_staged=$(jq -r '.cached_alias_count' <<< "$SLIVER_ARMORY_SUMMARY_JSON")
    else
        armory_status="disabled"
    fi

    install -d -m 0755 "$SLIVER_REGISTRY_ROOT"
    temporary="$SLIVER_REGISTRY_ROOT/.sliver.json.tmp"

    jq -n \
        --arg name "sliver" \
        --arg type "sliver" \
        --arg server "$server_path" \
        --arg client "$client_path" \
        --arg package_version "$package_version" \
        --arg server_command_version "$server_command_version" \
        --arg client_command_version "$client_command_version" \
        --arg target_user "$SLIVER_TARGET_USER_RESOLVED" \
        --arg target_home "$SLIVER_TARGET_HOME_RESOLVED" \
        --arg assets_status "initialized" \
        --arg server_root "$SLIVER_SERVER_ROOT" \
        --arg operator_config_status "valid" \
        --arg operator_config_path "$SLIVER_OPERATOR_CONFIG_RESOLVED" \
        --arg armory_mode "$SLIVER_ARMORY_MODE_RESOLVED" \
        --arg armory_status "$armory_status" \
        --arg armory_manifest "$armory_manifest" \
        --argjson extensions_expected "$extensions_expected" \
        --argjson extensions_staged "$extensions_staged" \
        --argjson aliases_expected "$aliases_expected" \
        --argjson aliases_staged "$aliases_staged" \
        --arg installed_at "$(date -Iseconds)" \
        '{
            name: $name,
            type: $type,
            server: $server,
            client: $client,
            package_version: $package_version,
            command_version: {
                server: $server_command_version,
                client: $client_command_version
            },
            target_user: $target_user,
            target_home: $target_home,
            assets_status: $assets_status,
            server_root: $server_root,
            operator_config_status: $operator_config_status,
            operator_config_path: $operator_config_path,
            armory_mode: $armory_mode,
            armory_status: $armory_status,
            armory_manifest: $armory_manifest,
            extensions_expected: $extensions_expected,
            extensions_staged: $extensions_staged,
            aliases_expected: $aliases_expected,
            aliases_staged: $aliases_staged,
            installed_at: $installed_at
        }' > "$temporary"

    mv "$temporary" "$SLIVER_REGISTRY_ROOT/sliver.json"
    chmod 0644 "$SLIVER_REGISTRY_ROOT/sliver.json"

    _sl_ok "Registered Sliver state at $SLIVER_REGISTRY_ROOT/sliver.json"

    return 0
}

validate_sliver_provisioning() {
    local server_path
    local client_path

    server_path=$(command -v sliver-server 2>/dev/null || true)
    client_path=$(command -v sliver-client 2>/dev/null || true)

    [ -n "$server_path" ] && [ -x "$server_path" ] || return 1
    [ -n "$client_path" ] && [ -x "$client_path" ] || return 1
    sliver_assets_valid || return 1
    sliver_operator_config_valid "$SLIVER_OPERATOR_CONFIG_RESOLVED" || return 1
    target_sliver_state_owned || return 1

    if [ "$SLIVER_ARMORY_MODE_RESOLVED" = "official" ]; then
        validate_sliver_armory_cache || return 1

        [[ "$(readlink -f "$SLIVER_CLIENT_ROOT_RESOLVED/extensions")" == \
            "$(readlink -f "$SLIVER_ARMORY_CACHE/extensions")" ]] ||
            return 1

        [[ "$(readlink -f "$SLIVER_CLIENT_ROOT_RESOLVED/aliases")" == \
            "$(readlink -f "$SLIVER_ARMORY_CACHE/aliases")" ]] ||
            return 1
    fi

    return 0
}

install_sliver() {
    invalidate_sliver_registry

    resolve_sliver_target || return 1
    resolve_sliver_armory_mode || return 1
    ensure_sliver_directories || return 1
    ensure_sliver_installed || return 1
    initialize_sliver_assets || return 1
    ensure_sliver_operator_config || return 1

    if [ "$SLIVER_ARMORY_MODE_RESOLVED" = "official" ]; then
        cache_sliver_armory || return 1
        stage_sliver_armory_for_target || return 1
    else
        _sl_log "Sliver Armory intentionally disabled by PORTALGUN_SLIVER_ARMORY_MODE=off"
    fi

    if ! validate_sliver_provisioning; then
        _sl_err "Sliver provisioning validation failed"
        return 1
    fi

    register_sliver || return 1

    _sl_ok "Sliver environment provisioned for $SLIVER_TARGET_USER_RESOLVED"
    return 0
}

update_sliver() {
    invalidate_sliver_registry
    sliver_direct_install || return 1
    install_sliver
}
