#!/usr/bin/env bash
# portalgun verify
# Audits the installed system against the bundle and reports what's actually
# present, partially present, or missing. Designed to be run after `install all`
# to confirm the environment is complete.

verify_install() {
    local bundle="${1:-$PORTALGUN_ROOT/portalgun_bundle.json}"
    [ -f "$bundle" ] || bundle="/opt/portalgun/portalgun_bundle.json"
    if [ ! -f "$bundle" ]; then
        print_error "No bundle found at $bundle"
        return 1
    fi

    print_status "Verifying install against: $bundle"
    echo

    local pass=0 warn=0 fail=0
    local PASS_MARK="\033[0;32m✓\033[0m"
    local WARN_MARK="\033[1;33m!\033[0m"
    local FAIL_MARK="\033[0;31m✗\033[0m"
    _row() { printf '  %b %-32s %s\n' "$1" "$2" "$3"; }

    # ── APT packages ────────────────────────────────────────────────
    echo "── APT packages ──────────────────────────"
    local apt_list
    apt_list=$(python3 -c "import json;d=json.load(open('$bundle'));print('\n'.join(d['tools']['apt']))")
    local apt_total=0
    local apt_installed=0
    local apt_missing=0
    local apt_profile_excluded=0
    local apt_profile_decision=0
    local active_profile="${PORTALGUN_PROFILE:-$(profile_resolve_name)}"

    # Some bundle entries are installed through direct binary downloads.
    # Treat an available command or binary as installed even if dpkg does
    # not know about it.
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue

        if declare -F profile_allows_apt_package >/dev/null 2>&1; then
            if profile_allows_apt_package "$pkg" "$active_profile"; then
                :
            else
                apt_profile_decision=$?

                case "$apt_profile_decision" in
                    1)
                        apt_profile_excluded=$((apt_profile_excluded + 1))
                        continue
                        ;;
                    *)
                        _row                             "$FAIL_MARK"                             "apt packages"                             "profile filter failed for '$active_profile'"

                        fail=$((fail + 1))
                        return "$apt_profile_decision"
                        ;;
                esac
            fi
        fi

        apt_total=$((apt_total + 1))

        if dpkg -s "$pkg" >/dev/null 2>&1 ||
            command -v "$pkg" >/dev/null 2>&1 ||
            [ -x "/usr/local/bin/$pkg" ] ||
            [ -x "/root/.local/bin/$pkg" ]
        then
            apt_installed=$((apt_installed + 1))
        else
            apt_missing=$((apt_missing + 1))
        fi
    done <<< "$apt_list"

    local apt_detail="$apt_installed/$apt_total required installed"

    if [ "$apt_profile_excluded" -gt 0 ]; then
        apt_detail="$apt_detail ($apt_profile_excluded profile-excluded)"
    fi

    if [ "$apt_missing" -eq 0 ]; then
        _row "$PASS_MARK" "apt packages" "$apt_detail"
        pass=$((pass + 1))
    else
        _row             "$WARN_MARK"             "apt packages"             "$apt_detail, $apt_missing missing"

        warn=$((warn + 1))
    fi

    # ── GitHub tools ────────────────────────────────────────────────
    echo "── GitHub tools ──────────────────────────"
    local gh_total gh_present=0 gh_missing=0
    gh_total=$(python3 -c "import json;d=json.load(open('$bundle'));print(len(d['tools']['github']))")
    while IFS=$'\t' read -r target raw_name; do
        # Different installers normalize dots/underscores differently. Try every
        # plausible variant and consider the tool present if ANY exists.
        local found=0 candidate
        for candidate in "$raw_name" \
                         "${raw_name//./-}" \
                         "${raw_name//./_}" \
                         "${raw_name//./}" \
                         "${raw_name//_/-}"; do
            if [ -d "$target/$candidate" ] && [ -n "$(ls -A "$target/$candidate" 2>/dev/null)" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            gh_present=$((gh_present + 1))
        else
            gh_missing=$((gh_missing + 1))
        fi
    done < <(python3 -c "
import json
d = json.load(open('$bundle'))
for g in d['tools']['github']:
    url = g['url']
    name = url.rstrip('/').replace('.git','').split('/')[-1].lower()
    print(g['target'] + '\t' + name)
")
    if [ "$gh_missing" -eq 0 ]; then
        _row "$PASS_MARK" "github tools" "$gh_present/$gh_total present"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "github tools" "$gh_present/$gh_total present ($gh_missing missing)"
        warn=$((warn + 1))
    fi

    # ── pip packages ────────────────────────────────────────────────
    echo "── pip packages ──────────────────────────"
    local pip_total pip_installed=0 pip_missing=0
    pip_total=$(python3 -c "import json;d=json.load(open('$bundle'));print(len(d['tools']['pip']))")
    if [ -x /opt/pentest-venv/bin/pip ]; then
        local installed_set
        # Normalize the same way pip does: lowercase + collapse _ → -
        installed_set=$(/opt/pentest-venv/bin/pip list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u)
        while IFS= read -r spec; do
            local pkg
            pkg=$(echo "$spec" | sed 's/[<>=!~].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -d ' ')
            if echo "$installed_set" | grep -qx "$pkg"; then
                pip_installed=$((pip_installed + 1))
            else
                pip_missing=$((pip_missing + 1))
            fi
        done < <(python3 -c "import json;d=json.load(open('$bundle'));print('\n'.join(d['tools']['pip']))")
        if [ "$pip_missing" -eq 0 ]; then
            _row "$PASS_MARK" "pip (pentest-venv)" "$pip_installed/$pip_total installed"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "pip (pentest-venv)" "$pip_installed/$pip_total installed ($pip_missing missing)"
            warn=$((warn + 1))
        fi
    else
        _row "$FAIL_MARK" "pip (pentest-venv)" "/opt/pentest-venv missing"
        fail=$((fail + 1))
    fi

    # ── cargo crates ────────────────────────────────────────────────
    echo "── cargo crates ──────────────────────────"

    local cargo_total
    local cargo_installed=0
    local cargo_missing=0
    local cargo_user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
    local cargo_home
    local cargo_path
    local cargo_list=""
    local -a cargo_runner

    cargo_total=$(
        python3 -c "
import json
data = json.load(open('$bundle'))
print(len(data['tools'].get('cargo', [])))
"
    )

    cargo_home=$(getent passwd "$cargo_user" | cut -d: -f6)

    if ! id "$cargo_user" >/dev/null 2>&1 ||
        [ -z "$cargo_home" ] ||
        [ ! -d "$cargo_home" ]
    then
        _row             "$FAIL_MARK"             "cargo crates"             "invalid target user: $cargo_user"

        fail=$((fail + 1))
    else
        cargo_path="$cargo_home/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        if [ "$(id -un)" = "$cargo_user" ]; then
            cargo_runner=(
                env
                HOME="$cargo_home"
                USER="$cargo_user"
                LOGNAME="$cargo_user"
                PATH="$cargo_path"
            )
        else
            cargo_runner=(
                sudo -H -u "$cargo_user"
                env
                HOME="$cargo_home"
                USER="$cargo_user"
                LOGNAME="$cargo_user"
                PATH="$cargo_path"
            )
        fi

        cargo_list=$(
            "${cargo_runner[@]}"                 cargo install --list 2>/dev/null || true
        )

        while IFS= read -r crate; do
            [ -n "$crate" ] || continue

            if printf '%s\n' "$cargo_list" |
                grep -q "^${crate} "
            then
                cargo_installed=$((cargo_installed + 1))
            else
                cargo_missing=$((cargo_missing + 1))
            fi
        done < <(
            python3 -c "
import json
data = json.load(open('$bundle'))
print('\n'.join(data['tools'].get('cargo', [])))
"
        )

        if [ "$cargo_missing" -eq 0 ]; then
            _row                 "$PASS_MARK"                 "cargo crates"                 "$cargo_installed/$cargo_total installed for $cargo_user"

            pass=$((pass + 1))
        else
            _row                 "$WARN_MARK"                 "cargo crates"                 "$cargo_installed/$cargo_total installed for $cargo_user ($cargo_missing missing)"

            warn=$((warn + 1))
        fi
    fi

    # ── Burp Suite Pro ───────────────────────────────────────────────
    echo "── Burp Suite Pro ────────────────────────"
    if [ -f /opt/portalgun/burpsuite/BurpSuitePro.jar ]; then
        local jar_size
        jar_size=$(stat -c %s /opt/portalgun/burpsuite/BurpSuitePro.jar 2>/dev/null || echo 0)
        if [ "$jar_size" -gt 100000000 ]; then
            _row "$PASS_MARK" "Burp Pro JAR" "$((jar_size / 1024 / 1024))MB"
            pass=$((pass + 1))
        else
            _row "$FAIL_MARK" "Burp Pro JAR" "too small ($jar_size bytes)"
            fail=$((fail + 1))
        fi
    else
        _row "$FAIL_MARK" "Burp Pro JAR" "missing"
        fail=$((fail + 1))
    fi
    if [ -x /usr/local/bin/burpsuite-pro ]; then
        _row "$PASS_MARK" "Burp launcher" "/usr/local/bin/burpsuite-pro"
        pass=$((pass + 1))
    else
        _row "$FAIL_MARK" "Burp launcher" "missing"
        fail=$((fail + 1))
    fi
    local bapp_manifest="/opt/portalgun/burpsuite/bapps/manifest.json"
    local bapp_require="${PORTALGUN_REQUIRE_BAPP_CACHE:-0}"

    if [ -f "$bapp_manifest" ] &&
        jq -e . "$bapp_manifest" >/dev/null 2>&1
    then
        local bapp_mode
        local bapp_official
        local bapp_cached
        local bapp_failures
        local bapp_actual

        bapp_mode=$(jq -r '.mode // "unknown"' "$bapp_manifest")
        bapp_official=$(jq -r '.summary.official_ids // 0' "$bapp_manifest")
        bapp_cached=$(jq -r '.summary.packages_cached // 0' "$bapp_manifest")
        bapp_failures=$(jq -r '.summary.failures // 0' "$bapp_manifest")

        bapp_actual=$(
            find /opt/portalgun/burpsuite/bapps/packages \
                -type f \
                -name '*.bapp' \
                2>/dev/null |
            wc -l
        )

        case "$bapp_mode" in
            official)
                if [ "$bapp_official" -gt 0 ] &&
                    [ "$bapp_cached" -eq "$bapp_official" ] &&
                    [ "$bapp_actual" -eq "$bapp_cached" ] &&
                    [ "$bapp_failures" -eq 0 ]
                then
                    _row \
                        "$PASS_MARK" \
                        "Official BApp cache" \
                        "$bapp_cached/$bapp_official official packages cached"

                    pass=$((pass + 1))
                elif [ "$bapp_require" = "1" ]; then
                    _row \
                        "$FAIL_MARK" \
                        "Official BApp cache" \
                        "$bapp_actual files; manifest=$bapp_cached/$bapp_official, failures=$bapp_failures"

                    fail=$((fail + 1))
                else
                    _row \
                        "$WARN_MARK" \
                        "Official BApp cache" \
                        "$bapp_actual files; manifest=$bapp_cached/$bapp_official, failures=$bapp_failures"

                    warn=$((warn + 1))
                fi
                ;;

            metadata)
                _row \
                    "$PASS_MARK" \
                    "Official BApp cache" \
                    "$bapp_official metadata records; packages disabled by policy"

                pass=$((pass + 1))
                ;;

            off)
                _row \
                    "$PASS_MARK" \
                    "Official BApp cache" \
                    "disabled by policy"

                pass=$((pass + 1))
                ;;

            *)
                if [ "$bapp_require" = "1" ]; then
                    _row \
                        "$FAIL_MARK" \
                        "Official BApp cache" \
                        "invalid manifest mode: $bapp_mode"

                    fail=$((fail + 1))
                else
                    _row \
                        "$WARN_MARK" \
                        "Official BApp cache" \
                        "invalid manifest mode: $bapp_mode"

                    warn=$((warn + 1))
                fi
                ;;
        esac
    elif [ "$bapp_require" = "1" ]; then
        _row \
            "$FAIL_MARK" \
            "Official BApp cache" \
            "required manifest is missing or invalid"

        fail=$((fail + 1))
    else
        _row \
            "$WARN_MARK" \
            "Official BApp cache" \
            "manifest missing; official packages were not cached"

        warn=$((warn + 1))
    fi

    if [ -f /opt/portalgun/burpsuite/license-import/prefs.xml ]; then
        _row "$PASS_MARK" "License imported" "license-import/prefs.xml present"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "License imported" "no prefs.xml — run: portalgun import burp-license <path>"
        warn=$((warn + 1))
    fi

    # ── Sliver ───────────────────────────────────────────────────────
    echo "── Sliver C2 ─────────────────────────────"

    local sliver_server_path=""
    local sliver_client_path=""
    local sliver_user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
    local sliver_passwd=""
    local sliver_uid=""
    local sliver_home=""
    local sliver_client_root=""
    local sliver_server_root="${PORTALGUN_SLIVER_SERVER_ROOT:-/opt/portalgun/sliver/server}"
    local sliver_cache_root="${PORTALGUN_SLIVER_ARMORY_CACHE:-/opt/portalgun/sliver/armory-cache}"
    local sliver_cache_helper="${PORTALGUN_LIB:-/opt/portalgun/lib}/cache_sliver_armory.py"
    local sliver_registry="/var/lib/portalgun/registry/sliver/sliver.json"
    local sliver_operator_name="${PORTALGUN_SLIVER_OPERATOR_NAME:-portalgun-local}"
    local sliver_operator_host="${PORTALGUN_SLIVER_OPERATOR_HOST:-127.0.0.1}"
    local sliver_operator_port="${PORTALGUN_SLIVER_OPERATOR_PORT:-31337}"
    local sliver_operator_config=""
    local sliver_mode="${PORTALGUN_SLIVER_ARMORY_MODE:-}"
    local sliver_registry_mode=""
    local sliver_registry_server_root=""
    local sliver_target_valid=0
    local sliver_assets_valid=0
    local sliver_operator_valid=0
    local sliver_cache_valid=0
    local sliver_target_state_valid=0
    local sliver_cache_summary=""
    local sliver_expected_extensions=0
    local sliver_actual_extensions=0
    local sliver_expected_aliases=0
    local sliver_actual_aliases=0
    local sliver_extension_sentinel=""
    local sliver_alias_sentinel=""

    sliver_server_path=$(command -v sliver-server 2>/dev/null || true)
    sliver_client_path=$(command -v sliver-client 2>/dev/null || true)

    if [ -n "$sliver_server_path" ] && [ -x "$sliver_server_path" ]; then
        _row "$PASS_MARK" "sliver-server" "$sliver_server_path"
        pass=$((pass + 1))
    else
        _row "$FAIL_MARK" "sliver-server" "missing or not executable"
        fail=$((fail + 1))
    fi

    if [ -n "$sliver_client_path" ] && [ -x "$sliver_client_path" ]; then
        _row "$PASS_MARK" "sliver-client" "$sliver_client_path"
        pass=$((pass + 1))
    else
        _row "$FAIL_MARK" "sliver-client" "missing or not executable"
        fail=$((fail + 1))
    fi

    sliver_passwd=$(getent passwd "$sliver_user" 2>/dev/null || true)

    if [ -n "$sliver_passwd" ]; then
        IFS=: read -r _ _ sliver_uid _ _ sliver_home _ \
            <<< "$sliver_passwd"

        if [ -n "$sliver_uid" ] &&
            [ -n "$sliver_home" ] &&
            [ -d "$sliver_home" ]
        then
            sliver_client_root="$sliver_home/.sliver-client"
            sliver_target_valid=1
        fi
    fi

    if [ "$sliver_target_valid" -eq 0 ]; then
        _row \
            "$FAIL_MARK" \
            "Sliver target user" \
            "invalid target user or home: $sliver_user"

        fail=$((fail + 1))
    else
        _row \
            "$PASS_MARK" \
            "Sliver target user" \
            "$sliver_user ($sliver_home)"

        pass=$((pass + 1))
    fi

    _verify_sliver_as_target() {
        if [ "$sliver_target_valid" -ne 1 ]; then
            return 1
        fi

        if [ "$(id -u)" = "$sliver_uid" ]; then
            env \
                HOME="$sliver_home" \
                USER="$sliver_user" \
                LOGNAME="$sliver_user" \
                SLIVER_ROOT_DIR="$sliver_server_root" \
                SLIVER_CLIENT_ROOT_DIR="$sliver_client_root" \
                TERM=dumb \
                "$@"

            return
        fi

        if ! command -v sudo >/dev/null 2>&1; then
            return 1
        fi

        sudo -u "$sliver_user" -- env \
            HOME="$sliver_home" \
            USER="$sliver_user" \
            LOGNAME="$sliver_user" \
            SLIVER_ROOT_DIR="$sliver_server_root" \
            SLIVER_CLIENT_ROOT_DIR="$sliver_client_root" \
            TERM=dumb \
            "$@"
    }

    if [ -f "$sliver_registry" ] &&
        jq -e 'type == "object"' "$sliver_registry" >/dev/null 2>&1
    then
        sliver_registry_mode=$(
            jq -r '.armory_mode // empty' "$sliver_registry"
        )
        sliver_registry_server_root=$(
            jq -r '.server_root // empty' "$sliver_registry"
        )
        sliver_operator_config=$(
            jq -r '.operator_config_path // empty' "$sliver_registry"
        )

        if [ -z "$sliver_mode" ]; then
            sliver_mode="$sliver_registry_mode"
        fi

        if [ -z "${PORTALGUN_SLIVER_SERVER_ROOT:-}" ] &&
            [ -n "$sliver_registry_server_root" ]
        then
            sliver_server_root="$sliver_registry_server_root"
        fi
    fi

    if [ -z "$sliver_mode" ]; then
        sliver_mode="official"
    fi

    if [ -z "$sliver_operator_config" ] &&
        [ "$sliver_target_valid" -eq 1 ]
    then
        sliver_operator_config="$sliver_client_root/configs/${sliver_operator_name}_${sliver_operator_host}.cfg"
    fi

    if [ "$sliver_target_valid" -eq 1 ] &&
        [ -s "$sliver_server_root/configs/server.yaml" ] &&
        [ -s "$sliver_server_root/configs/database.yaml" ] &&
        [ -s "$sliver_server_root/sliver.db" ] &&
        [ -s "$sliver_server_root/nouns.txt" ] &&
        [ -s "$sliver_server_root/adjectives.txt" ] &&
        [ -x "$sliver_server_root/go/bin/go" ] &&
        [ -x "$sliver_server_root/zig/zig" ] &&
        _verify_sliver_as_target test -r "$sliver_server_root/configs/server.yaml" &&
        _verify_sliver_as_target test -r "$sliver_server_root/sliver.db"
    then
        sliver_assets_valid=1

        _row \
            "$PASS_MARK" \
            "Sliver assets" \
            "initialized at $sliver_server_root"

        pass=$((pass + 1))
    else
        _row \
            "$FAIL_MARK" \
            "Sliver assets" \
            "required initialized assets are missing or unreadable"

        fail=$((fail + 1))
    fi

    if [ "$sliver_target_valid" -eq 1 ] &&
        [ -n "$sliver_operator_config" ] &&
        [ -s "$sliver_operator_config" ] &&
        [ "$(stat -c '%u' "$sliver_operator_config" 2>/dev/null || true)" = "$sliver_uid" ] &&
        [ "$(stat -c '%a' "$sliver_operator_config" 2>/dev/null || true)" = "600" ] &&
        _verify_sliver_as_target test -r "$sliver_operator_config" &&
        python3 - \
            "$sliver_operator_config" \
            "$sliver_operator_name" \
            "$sliver_operator_host" \
            "$sliver_operator_port" << 'PY_SLIVER_CONFIG'
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

for key in (
    "operator",
    "lhost",
    "ca_certificate",
    "certificate",
    "private_key",
    "token",
):
    if not isinstance(value.get(key), str) or not value[key]:
        raise SystemExit(1)

if value["operator"] != expected_operator:
    raise SystemExit(1)

if value["lhost"] != expected_host:
    raise SystemExit(1)

if value.get("lport") != expected_port:
    raise SystemExit(1)
PY_SLIVER_CONFIG
    then
        sliver_operator_valid=1

        _row \
            "$PASS_MARK" \
            "Sliver operator config" \
            "valid for $sliver_user"

        pass=$((pass + 1))
    else
        _row \
            "$FAIL_MARK" \
            "Sliver operator config" \
            "missing, invalid, unreadable, or incorrectly owned"

        fail=$((fail + 1))
    fi

    if [ "$sliver_target_valid" -eq 1 ] &&
        [ -d "$sliver_client_root" ] &&
        [ -z "$(
            find "$sliver_client_root" \
                -xdev \
                ! -uid "$sliver_uid" \
                -print -quit 2>/dev/null
        )" ]
    then
        sliver_target_state_valid=1

        _row \
            "$PASS_MARK" \
            "Sliver target state" \
            "owned by $sliver_user"

        pass=$((pass + 1))
    else
        _row \
            "$FAIL_MARK" \
            "Sliver target state" \
            "missing or contains non-$sliver_user-owned entries"

        fail=$((fail + 1))
    fi

    case "$sliver_mode" in
        official)
            if [ ! -f "$sliver_cache_helper" ]; then
                _row \
                    "$FAIL_MARK" \
                    "Sliver cache manifest" \
                    "cache validator is missing: $sliver_cache_helper"

                fail=$((fail + 1))
            elif ! sliver_cache_summary=$(
                python3 "$sliver_cache_helper" validate \
                    --cache-root "$sliver_cache_root" \
                    --json 2>/dev/null
            ); then
                _row \
                    "$FAIL_MARK" \
                    "Sliver cache manifest" \
                    "missing, incomplete, corrupt, or inconsistent"

                fail=$((fail + 1))
            elif ! jq -e '
                .status == "complete" and
                .cached_extension_count == .expected_extension_count and
                .cached_alias_count == .expected_alias_count
            ' <<< "$sliver_cache_summary" >/dev/null 2>&1
            then
                _row \
                    "$FAIL_MARK" \
                    "Sliver cache manifest" \
                    "validator returned an incomplete cache"

                fail=$((fail + 1))
            else
                sliver_expected_extensions=$(
                    jq -r '.expected_extension_count' \
                        <<< "$sliver_cache_summary"
                )
                sliver_actual_extensions=$(
                    jq -r '.cached_extension_count' \
                        <<< "$sliver_cache_summary"
                )
                sliver_expected_aliases=$(
                    jq -r '.expected_alias_count' \
                        <<< "$sliver_cache_summary"
                )
                sliver_actual_aliases=$(
                    jq -r '.cached_alias_count' \
                        <<< "$sliver_cache_summary"
                )

                sliver_extension_sentinel=$(
                    jq -r '
                        [
                            .packages[]
                            | select(.type == "extension")
                            | .command_name
                        ][0] // empty
                    ' "$sliver_cache_root/manifest.json"
                )
                sliver_alias_sentinel=$(
                    jq -r '
                        [
                            .packages[]
                            | select(.type == "alias")
                            | .command_name
                        ][0] // empty
                    ' "$sliver_cache_root/manifest.json"
                )

                if [ ! -f "$sliver_registry" ] ||
                    ! jq -e \
                        --arg mode "$sliver_mode" \
                        --arg target_user "$sliver_user" \
                        --arg target_home "$sliver_home" \
                        --arg manifest "$sliver_cache_root/manifest.json" \
                        --argjson extensions_expected "$sliver_expected_extensions" \
                        --argjson extensions_staged "$sliver_actual_extensions" \
                        --argjson aliases_expected "$sliver_expected_aliases" \
                        --argjson aliases_staged "$sliver_actual_aliases" \
                        '
                            .armory_mode == $mode and
                            .armory_status == "complete" and
                            .target_user == $target_user and
                            .target_home == $target_home and
                            .armory_manifest == $manifest and
                            .extensions_expected == $extensions_expected and
                            .extensions_staged == $extensions_staged and
                            .aliases_expected == $aliases_expected and
                            .aliases_staged == $aliases_staged
                        ' "$sliver_registry" >/dev/null 2>&1
                then
                    _row \
                        "$FAIL_MARK" \
                        "Sliver cache manifest" \
                        "cache is complete but registry state is missing or inconsistent"

                    fail=$((fail + 1))
                else
                    sliver_cache_valid=1

                    _row \
                        "$PASS_MARK" \
                        "Sliver cache manifest" \
                        "complete and registry-consistent"

                    pass=$((pass + 1))
                fi
            fi

            if [ "$sliver_cache_valid" -eq 1 ] &&
                [ "$sliver_target_valid" -eq 1 ] &&
                [ -L "$sliver_client_root/extensions" ] &&
                [[ "$(readlink -f "$sliver_client_root/extensions" 2>/dev/null || true)" == \
                    "$(readlink -f "$sliver_cache_root/extensions" 2>/dev/null || true)" ]]
            then
                _row \
                    "$PASS_MARK" \
                    "Sliver extensions" \
                    "$sliver_actual_extensions/$sliver_expected_extensions staged for $sliver_user"

                pass=$((pass + 1))
            else
                _row \
                    "$FAIL_MARK" \
                    "Sliver extensions" \
                    "required complete extension cache is not staged"

                fail=$((fail + 1))
            fi

            if [ "$sliver_cache_valid" -eq 1 ] &&
                [ "$sliver_target_valid" -eq 1 ] &&
                [ -L "$sliver_client_root/aliases" ] &&
                [[ "$(readlink -f "$sliver_client_root/aliases" 2>/dev/null || true)" == \
                    "$(readlink -f "$sliver_cache_root/aliases" 2>/dev/null || true)" ]]
            then
                _row \
                    "$PASS_MARK" \
                    "Sliver aliases" \
                    "$sliver_actual_aliases/$sliver_expected_aliases staged for $sliver_user"

                pass=$((pass + 1))
            else
                _row \
                    "$FAIL_MARK" \
                    "Sliver aliases" \
                    "required complete alias cache is not staged"

                fail=$((fail + 1))
            fi
            ;;
        off)
            if [ -n "$sliver_registry_mode" ] &&
                [ "$sliver_registry_mode" != "off" ]
            then
                _row \
                    "$FAIL_MARK" \
                    "Sliver cache manifest" \
                    "requested off policy conflicts with registry mode"

                fail=$((fail + 1))
            else
                sliver_cache_valid=1

                _row \
                    "$PASS_MARK" \
                    "Sliver cache manifest" \
                    "Armory intentionally disabled by explicit policy"

                _row \
                    "$PASS_MARK" \
                    "Sliver extensions" \
                    "intentionally disabled"

                _row \
                    "$PASS_MARK" \
                    "Sliver aliases" \
                    "intentionally disabled"

                pass=$((pass + 3))
            fi
            ;;
        *)
            _row \
                "$FAIL_MARK" \
                "Sliver cache manifest" \
                "invalid Armory mode: $sliver_mode"

            _row \
                "$FAIL_MARK" \
                "Sliver extensions" \
                "cannot validate under invalid Armory mode"

            _row \
                "$FAIL_MARK" \
                "Sliver aliases" \
                "cannot validate under invalid Armory mode"

            fail=$((fail + 3))
            ;;
    esac

    # ── Burp smoke test ─────────────────────────────────────────────
    echo "── Burp smoke test ───────────────────────"
    if [ -f /opt/portalgun/burpsuite/BurpSuitePro.jar ]; then
        local burp_ver
        burp_ver=$(timeout 30 java -jar /opt/portalgun/burpsuite/BurpSuitePro.jar --version 2>/dev/null | head -1)

        if echo "$burp_ver" | grep -q "Burp Suite"; then
            _row "$PASS_MARK" "Burp JAR loads" "$(echo "$burp_ver" | head -c 80)"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "Burp JAR loads" "version probe returned: $burp_ver"
            warn=$((warn + 1))
        fi
    fi

    # ── Sliver smoke test ───────────────────────────────────────────
    echo "── Sliver smoke test ─────────────────────"

    local sliver_smoke_dir=""
    local sliver_smoke_rc=0
    local sliver_smoke_valid=0

    if [ -n "$sliver_server_path" ] &&
        [ -x "$sliver_server_path" ] &&
        [ "$sliver_target_valid" -eq 1 ] &&
        [ "$sliver_assets_valid" -eq 1 ] &&
        [ "$sliver_operator_valid" -eq 1 ] &&
        [ "$sliver_target_state_valid" -eq 1 ] &&
        [ "$sliver_cache_valid" -eq 1 ]
    then
        sliver_smoke_dir=$(
            mktemp -d /tmp/portalgun-verify-sliver.XXXXXX
        )

        if [ "$sliver_mode" = "official" ]; then
            cat > "$sliver_smoke_dir/verify.rc" << 'RC_SLIVER'
extensions
aliases
exit
RC_SLIVER
        else
            cat > "$sliver_smoke_dir/verify.rc" << 'RC_SLIVER'
exit
RC_SLIVER
        fi

        if [ "$(id -u)" = "0" ]; then
            chown -R "$sliver_uid" "$sliver_smoke_dir"
        fi

        _verify_sliver_as_target \
            timeout 180 \
            "$sliver_server_path" \
            --rc "$sliver_smoke_dir/verify.rc" \
            > "$sliver_smoke_dir/output.raw" 2>&1 ||
            sliver_smoke_rc=$?

        sed -E $'s/\033\\[[0-9;?]*[ -\\/]*[@-~]//g' \
            "$sliver_smoke_dir/output.raw" \
            > "$sliver_smoke_dir/output.clean"

        if [ "$sliver_smoke_rc" -eq 0 ] &&
            ! grep -Eiq \
                'unknown command|command not found|panic:|fatal:' \
                "$sliver_smoke_dir/output.clean"
        then
            if [ "$sliver_mode" = "official" ]; then
                if [ -n "$sliver_extension_sentinel" ] &&
                    [ -n "$sliver_alias_sentinel" ] &&
                    python3 - \
                        "$sliver_smoke_dir/output.clean" \
                        "$sliver_extension_sentinel" \
                        "$sliver_alias_sentinel" << 'PY_SLIVER_SMOKE'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(
    encoding="utf-8",
    errors="replace",
)

for command in sys.argv[2:]:
    if not any(command in line.split() for line in text.splitlines()):
        raise SystemExit(1)
PY_SLIVER_SMOKE
                then
                    sliver_smoke_valid=1
                fi
            else
                sliver_smoke_valid=1
            fi
        fi

        rm -rf "$sliver_smoke_dir"
    fi

    if [ "$sliver_smoke_valid" -eq 1 ]; then
        if [ "$sliver_mode" = "official" ]; then
            _row \
                "$PASS_MARK" \
                "Sliver console" \
                "target-user extension and alias state verified"
        else
            _row \
                "$PASS_MARK" \
                "Sliver console" \
                "target-user console initialized; Armory disabled"
        fi

        pass=$((pass + 1))
    else
        _row \
            "$FAIL_MARK" \
            "Sliver console" \
            "target-user console validation failed"

        fail=$((fail + 1))
    fi

    # ── Web UI ───────────────────────────────────────────────────────
    echo "── Web UI ────────────────────────────────"
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:1337/ 2>/dev/null | grep -q 200; then
        _row "$PASS_MARK" "tools_server :1337" "HTTP 200"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "tools_server :1337" "not responding (start with: systemctl start tools-server)"
        warn=$((warn + 1))
    fi
    if [ -f /opt/tools-docs/portalgun_tools.json ]; then
        local manifest_total
        manifest_total=$(python3 -c "import json;d=json.load(open('/opt/tools-docs/portalgun_tools.json'));print(d.get('totals',{}).get('total','?'))" 2>/dev/null)
        _row "$PASS_MARK" "web manifest" "$manifest_total tools listed"
        pass=$((pass + 1))
    else
        _row "$FAIL_MARK" "web manifest" "missing"
        fail=$((fail + 1))
    fi

    # ── Active terminal profile ─────────────────────────────────────
    echo "── Terminal profile ──────────────────────"
    if ! declare -F profile_verify >/dev/null 2>&1 && [ -f "${PORTALGUN_LIB:-/opt/portalgun/lib}/profile.sh" ]; then
        source "${PORTALGUN_LIB:-/opt/portalgun/lib}/profile.sh"
    fi
    if declare -F profile_verify >/dev/null 2>&1; then
        local active_profile
        active_profile=$(profile_resolve_name "${PORTALGUN_PROFILE:-}")
        if profile_verify "$active_profile"; then
            _row "$PASS_MARK" "terminal profile" "$active_profile"
            pass=$((pass + 1))
        else
            _row "$FAIL_MARK" "terminal profile" "$active_profile failed verification"
            fail=$((fail + 1))
        fi
    else
        _row "$WARN_MARK" "terminal profile" "profile engine unavailable"
        warn=$((warn + 1))
    fi

    # ── Registry ─────────────────────────────────────────────────────
    echo "── Registry ──────────────────────────────"
    local reg_apt reg_gh reg_pip reg_cargo
    reg_apt=$(find /var/lib/portalgun/registry/apt -name '*.json' 2>/dev/null | wc -l)
    reg_gh=$(find /var/lib/portalgun/registry/github -name '*.json' 2>/dev/null | wc -l)
    reg_pip=$(find /var/lib/portalgun/registry/pip -name '*.json' 2>/dev/null | wc -l)
    reg_cargo=$(find /var/lib/portalgun/registry/cargo -name '*.json' 2>/dev/null | wc -l)
    _row "$PASS_MARK" "registry" "apt=$reg_apt github=$reg_gh pip=$reg_pip cargo=$reg_cargo"

    # ── Summary ──────────────────────────────────────────────────────
    echo
    echo "════════════════════════════════════════"
    printf '  Passed:  %d\n  Warnings: %d\n  Failed:  %d\n' "$pass" "$warn" "$fail"
    echo "════════════════════════════════════════"
    if [ "$fail" -gt 0 ]; then
        return 2
    elif [ "$warn" -gt 0 ]; then
        return 1
    fi
    return 0
}
