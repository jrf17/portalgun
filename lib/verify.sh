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
    local bapp_count=0
    [ -d /opt/portalgun/burpsuite/bapps ] && \
        bapp_count=$(find /opt/portalgun/burpsuite/bapps -maxdepth 1 -mindepth 1 -type d | wc -l)
    if [ "$bapp_count" -ge 450 ]; then
        _row "$PASS_MARK" "BApps cached" "$bapp_count entries"
        pass=$((pass + 1))
    elif [ "$bapp_count" -gt 0 ]; then
        _row "$WARN_MARK" "BApps cached" "$bapp_count entries (expected ~499)"
        warn=$((warn + 1))
    else
        _row "$FAIL_MARK" "BApps cached" "0 — bundle preload failed"
        fail=$((fail + 1))
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
    command -v sliver-server >/dev/null 2>&1 && \
        { _row "$PASS_MARK" "sliver-server" "$(command -v sliver-server)"; pass=$((pass+1)); } || \
        { _row "$FAIL_MARK" "sliver-server" "missing"; fail=$((fail+1)); }
    command -v sliver-client >/dev/null 2>&1 && \
        { _row "$PASS_MARK" "sliver-client" "$(command -v sliver-client)"; pass=$((pass+1)); } || \
        { _row "$FAIL_MARK" "sliver-client" "missing"; fail=$((fail+1)); }
    local ext_count=0 alias_count=0
    [ -d /root/.sliver-client/extensions ] && \
        ext_count=$(find /root/.sliver-client/extensions -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    [ -d /root/.sliver-client/aliases ] && \
        alias_count=$(find /root/.sliver-client/aliases -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    if [ "$ext_count" -ge 140 ]; then
        _row "$PASS_MARK" "Sliver extensions" "$ext_count staged"
        pass=$((pass + 1))
    elif [ "$ext_count" -gt 0 ]; then
        _row "$WARN_MARK" "Sliver extensions" "$ext_count staged (expected ~152)"
        warn=$((warn + 1))
    else
        _row "$FAIL_MARK" "Sliver extensions" "0 — bundled armory missing"
        fail=$((fail + 1))
    fi
    if [ "$alias_count" -ge 20 ]; then
        _row "$PASS_MARK" "Sliver aliases" "$alias_count staged"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "Sliver aliases" "$alias_count staged (expected ~22)"
        warn=$((warn + 1))
    fi

    # ── Burp smoke test ─────────────────────────────────────────────
    echo "── Burp smoke test ───────────────────────"
    if [ -f /opt/portalgun/burpsuite/BurpSuitePro.jar ]; then
        # Lightweight: --help exits fast, proves Java can load the JAR
        local burp_ver
        burp_ver=$(timeout 30 java -jar /opt/portalgun/burpsuite/BurpSuitePro.jar --version 2>/dev/null | head -1)
        if echo "$burp_ver" | grep -q "Burp Suite"; then
            _row "$PASS_MARK" "Burp JAR loads" "$(echo $burp_ver | head -c 80)"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "Burp JAR loads" "version probe returned: $burp_ver"
            warn=$((warn + 1))
        fi
    fi

    # ── Sliver smoke test ───────────────────────────────────────────
    echo "── Sliver smoke test ─────────────────────"
    if command -v sliver-server >/dev/null 2>&1; then
        cat > /tmp/pg-verify-sliver.rc <<'RC'
extensions
exit
RC
        local sl_installed
        sl_installed=$(timeout 30 sliver-server --rc /tmp/pg-verify-sliver.rc 2>&1 | \
                        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -cE "✅" || true)
        rm -f /tmp/pg-verify-sliver.rc
        if [ "$sl_installed" -ge 30 ]; then
            _row "$PASS_MARK" "Sliver console" "lists $sl_installed installed in --rc check"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "Sliver console" "only $sl_installed installed entries showed"
            warn=$((warn + 1))
        fi
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
