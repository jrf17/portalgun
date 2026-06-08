#!/bin/bash
# portalgun apply — install all tools from a bundle JSON

# Phase time weights (based on observed install times):
#   apt:    35%  (0–35)
#   github: 45%  (35–80)
#   pip:    15%  (80–95)
#   cargo:  5%   (95–100)
_progress() {
    local pct="$1" label="$2"
    echo "PROGRESS:${pct}:${label}"
}



# Profile engine is optional only for compatibility with older installed trees.
# Current Portalgun installs always ship it.
if [ -f "${PORTALGUN_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/profile.sh" ]; then
    # shellcheck source=lib/profile.sh
    source "${PORTALGUN_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/profile.sh"
fi

apply_bundle() {
    # Separate bundle file from flags — first non-flag arg is the bundle path
    local bundle_file=""
    local run_apt=1 run_github=1 run_pip=1 run_cargo=1
    for arg in "$@"; do
        if [[ "$arg" != --* ]] && [ -z "$bundle_file" ]; then
            bundle_file="$arg"
            continue
        fi
        case "$arg" in
            --only-apt)    run_github=0; run_pip=0; run_cargo=0 ;;
            --only-github) run_apt=0;    run_pip=0; run_cargo=0 ;;
            --only-pip)    run_apt=0;    run_github=0; run_cargo=0 ;;
            --only-cargo)  run_apt=0;    run_github=0; run_pip=0 ;;
            --skip-apt)    run_apt=0 ;;
            --skip-github) run_github=0 ;;
            --skip-pip)    run_pip=0 ;;
            --skip-cargo)  run_cargo=0 ;;
            --phases=*)
                local phases="${arg#--phases=}"
                run_apt=0; run_github=0; run_pip=0; run_cargo=0
                echo "$phases" | grep -q "apt"    && run_apt=1
                echo "$phases" | grep -q "github" && run_github=1
                echo "$phases" | grep -q "pip"    && run_pip=1
                echo "$phases" | grep -q "cargo"  && run_cargo=1
                ;;
        esac
    done

    if [ -z "$bundle_file" ]; then
        for candidate in \
            "$PORTALGUN_REPO_DIR/portalgun_bundle.json" \
            "$PORTALGUN_REPO_DIR/data/portalgun_bundle.json" \
            "/opt/portalgun/portalgun_bundle.json" \
            "/home/kali/portalgun/portalgun_bundle.json" \
            "./portalgun_bundle.json"; do
            if [ -f "$candidate" ]; then
                bundle_file="$candidate"
                break
            fi
        done
    fi

    if [ -z "$bundle_file" ] || [ ! -f "$bundle_file" ]; then
        print_error "No portalgun_bundle.json found. Run: portalgun export"
        exit 1
    fi

    require_root install all "$bundle_file"

    if ! jq empty "$bundle_file" 2>/dev/null; then
        print_error "Invalid JSON: $bundle_file"
        exit 1
    fi

    local version
    version=$(jq -r '.version // "?"' "$bundle_file")
    local apt_count github_count pip_count cargo_count
    apt_count=$(jq '.tools.apt | length'             "$bundle_file")
    github_count=$(jq '.tools.github | length'       "$bundle_file")
    pip_count=$(jq '(.tools.pip // []) | length'     "$bundle_file")
    cargo_count=$(jq '(.tools.cargo // []) | length' "$bundle_file")

    _progress 0 "Starting install..."
    print_status "Applying bundle (v${version}): $apt_count apt, $github_count github, $pip_count pip, $cargo_count cargo"
    echo ""

    # ── APT (0–35%) ──────────────────────────────────────────────────
    if [ "$apt_count" -gt 0 ] && [ "$run_apt" -eq 1 ]; then
        _progress 1 "Phase 1: Resolving apt packages..."
        print_status "Phase 1: apt packages ($apt_count)"

        local apt_needed=()
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            # Skip if either the registry knows about it OR dpkg shows it
            # installed system-wide. Falling back to dpkg keeps idempotency
            # honest when apt was driven by install.sh's legacy path (which
            # doesn't touch the registry) or by manual sysadmin work.
            if registry_exists apt "$pkg" || dpkg -s "$pkg" >/dev/null 2>&1; then
                continue
            fi
            apt_needed+=("$pkg")
        done < <(jq -r '.tools.apt[]' "$bundle_file")

        local apt_skip=$(( apt_count - ${#apt_needed[@]} ))
        local apt_total=${#apt_needed[@]}
        print_status "  $apt_skip already installed, $apt_total to install"

        if [ "$apt_total" -gt 0 ]; then
            _progress 2 "Phase 1: Downloading apt packages ($apt_total)..."
            local apt_done=0
            # Use process substitution (not pipe) to avoid subshell variable loss
            while IFS= read -r line; do
                if echo "$line" | grep -qE "^Setting up|^Unpacking"; then
                    local pkg_name
                    pkg_name=$(echo "$line" | sed 's/^Setting up //;s/^Unpacking //' | grep -oE '^[a-z][a-z0-9.+_-]+')
                    (( apt_done++ )) || true
                    local display_done=$(( apt_done > apt_total ? apt_total : apt_done ))
                    local pct=$(( 2 + ( display_done * 32 / apt_total ) ))
                    [ "$pct" -gt 34 ] && pct=34
                    _progress "$pct" "Phase 1: apt [$display_done/$apt_total] $pkg_name"
                    printf "  ${BLUE}[apt]${NC} [%d/%d] %s\n" "$display_done" "$apt_total" "$pkg_name"
                fi
            done < <(DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_needed[@]}" 2>&1)

            for pkg in "${apt_needed[@]}"; do
                if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                    local version_str
                    version_str=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "unknown")
                    local json
                    json=$(jq -n \
                        --arg name    "$pkg" \
                        --arg package "$pkg" \
                        --arg version "$version_str" \
                        --arg added   "$(date -Iseconds)" \
                        '{name:$name,type:"apt",package:$package,version:$version,status:"ok",added:$added}')
                    registry_write apt "$pkg" "$json"
                fi
            done
        fi

        _progress 35 "Phase 1: apt complete"
        print_status "apt phase complete"
        echo ""
    fi

    # ── GitHub (35–80%) ──────────────────────────────────────────────
    if [ "$github_count" -gt 0 ] && [ "$run_github" -eq 1 ]; then
        _progress 36 "Phase 2: Cloning GitHub tools..."
        print_status "Phase 2: github tools ($github_count)"
        local gh_ok=0 gh_skip=0 gh_fail=0 gh_done=0

        while IFS= read -r entry; do
            local url target name
            url=$(echo "$entry" | jq -r '.url')
            target=$(echo "$entry" | jq -r '.target // "/opt/tools/misc"')
            name=$(basename "$url" .git | tr '[:upper:]' '[:lower:]')
            gh_done=$(( gh_done + 1 ))

            # github occupies 36–79%
            local pct=$(( 36 + ( gh_done * 43 / github_count ) ))
            _progress "$pct" "Phase 2: GitHub [$gh_done/$github_count] $name"

            # Idempotency: registry knows about it OR the tool_dir exists on
            # disk with content (handles legacy install_github_tools.sh which
            # doesn't write the registry).
            local tool_dir="$target/$name"
            if registry_exists github "${name}_" || \
               { [ -d "$tool_dir" ] && [ -n "$(ls -A "$tool_dir" 2>/dev/null)" ]; }; then
                printf "  ${CYAN}[skip]${NC} %s\n" "$name"
                (( gh_skip++ )) || true
            else
                printf "  ${BLUE}[git]${NC}  %s ... " "$name"
                if portalgun install github "$url" "$target" >/dev/null 2>&1; then
                    printf "${GREEN}ok${NC}\n"
                    (( gh_ok++ )) || true
                else
                    printf "${RED}FAILED${NC}\n"
                    (( gh_fail++ )) || true
                fi
            fi
        done < <(jq -c '.tools.github[]' "$bundle_file")

        _progress 80 "Phase 2: GitHub complete"
        echo ""
        print_status "github: $gh_ok installed, $gh_skip skipped, $gh_fail failed"
        echo ""
    fi

    # ── pip (80–95%) — installed into shared venv /opt/pentest-venv ──
    local VENV="/opt/pentest-venv"
    local VENV_PIP="$VENV/bin/pip"

    if [ "$pip_count" -gt 0 ] && [ "$run_pip" -eq 1 ]; then
        _progress 81 "Phase 3: Setting up /opt/pentest-venv..."
        print_status "Phase 3: pip packages ($pip_count) → $VENV"

        # Create venv if needed
        if [ ! -f "$VENV_PIP" ]; then
            print_status "  Creating venv at $VENV..."
            python3 -m venv "$VENV"
            "$VENV_PIP" install --quiet --upgrade pip setuptools wheel
        fi

        # System build-deps for native pip packages (dbus-python, pycairo, etc.)
        # Without these, single-package builds abort the entire batch.
        local pip_build_deps="libdbus-1-dev libgirepository1.0-dev libcairo2-dev pkg-config python3-dev libffi-dev libssl-dev libxml2-dev libxslt1-dev libpcap-dev libkrb5-dev libldap2-dev libsasl2-dev"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q $pip_build_deps >/dev/null 2>&1 || \
            print_warning "Some pip build-deps could not be installed"

        # Write requirements.txt
        local req_file
        req_file=$(mktemp /tmp/portalgun_req_XXXXXX.txt)
        jq -r '(.tools.pip // [])[]' "$bundle_file" > "$req_file"
        local pip_total
        pip_total=$(wc -l < "$req_file")

        print_status "  Installing $pip_total packages via requirements.txt..."
        _progress 82 "Phase 3: pip — resolving and installing $pip_total packages..."

        # Phase A: bulk install — fast path, gets ~95% of packages in ~3min
        local pip_tmp pip_fail_log
        pip_tmp=$(mktemp /tmp/pg_pip_XXXXXX.tmp)
        chmod 600 "$pip_tmp"
        pip_fail_log="$PORTALGUN_LOG_DIR/pip_failures.log"
        : > "$pip_fail_log"
        "$VENV_PIP" install --prefer-binary -r "$req_file" 2>&1 | tee "$pip_tmp" | \
            grep -E "^(ERROR|Successfully installed)" | tail -20 || true

        # Phase B: discover what didn't make it and retry per-package so one
        # build failure doesn't abort the rest.
        local installed_set
        installed_set=$("$VENV_PIP" list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u)
        local missing_pip=() pkg_name_only
        while IFS= read -r spec; do
            [ -z "$spec" ] && continue
            pkg_name_only=$(echo "$spec" | sed 's/[<>=!~].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -d ' ')
            echo "$installed_set" | grep -qx "$pkg_name_only" || missing_pip+=("$spec")
        done < "$req_file"

        if [ "${#missing_pip[@]}" -gt 0 ]; then
            print_status "  Retrying ${#missing_pip[@]} stragglers individually..."
            local retry_done=0 retry_ok=0 retry_fail=0
            for spec in "${missing_pip[@]}"; do
                retry_done=$((retry_done + 1))
                if "$VENV_PIP" install --quiet --prefer-binary "$spec" >/dev/null 2>>"$pip_fail_log"; then
                    retry_ok=$((retry_ok + 1))
                else
                    echo "  $spec" >> "$pip_fail_log"
                    retry_fail=$((retry_fail + 1))
                fi
            done
            print_status "  Stragglers: $retry_ok installed, $retry_fail failed (log: $pip_fail_log)"
        fi
        rm -f "$pip_tmp" "$req_file"

        # Register only pip packages that ACTUALLY installed. Avoids the
        # earlier bug where 822 registry entries existed but only 3 packages
        # were truly in the venv.
        local final_installed
        final_installed=$("$VENV_PIP" list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u)
        while IFS= read -r pkg_spec; do
            [ -z "$pkg_spec" ] && continue
            local pkg_name pkg_ver safe_id
            pkg_name=$(echo "$pkg_spec" | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            pkg_ver=$(echo "$pkg_spec" | cut -d= -f3)
            safe_id=$(echo "$pkg_name" | tr -cs 'a-z0-9._-' '_')
            # Only register if pip list shows it installed
            if echo "$final_installed" | grep -qx "$pkg_name" && ! registry_exists pip "$safe_id"; then
                local json
                json=$(jq -n \
                    --arg name    "$pkg_name" \
                    --arg package "$pkg_spec" \
                    --arg version "$pkg_ver" \
                    --arg added   "$(date -Iseconds)" \
                    '{name:$name,type:"pip",package:$package,version:$version,status:"ok",added:$added}')
                registry_write pip "$safe_id" "$json"
            fi
        done < <(jq -r '(.tools.pip // [])[]' "$bundle_file")

        _progress 95 "Phase 3: pip complete"
        print_status "pip phase complete"
        echo ""
    fi

    # ── cargo (95–100%) ──────────────────────────────────────────────
    if [ "$cargo_count" -gt 0 ] && [ "$run_cargo" -eq 1 ]; then
        _progress 96 "Phase 4: Installing cargo tools..."
        print_status "Phase 4: cargo packages ($cargo_count)"

        if ! command -v cargo >/dev/null 2>&1; then
            print_warning "cargo not found — skipping cargo phase"
        else
            local cargo_ok=0 cargo_skip=0 cargo_fail=0 cargo_done=0

            while IFS= read -r pkg_name; do
                [ -z "$pkg_name" ] && continue
                cargo_done=$(( cargo_done + 1 ))
                local safe_id
                safe_id=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')
                local pct=$(( 96 + ( cargo_done * 3 / cargo_count ) ))
                _progress "$pct" "Phase 4: cargo [$cargo_done/$cargo_count] $pkg_name"

                if registry_exists cargo "$safe_id"; then
                    printf "  ${CYAN}[skip]${NC} %s\n" "$pkg_name"
                    (( cargo_skip++ )) || true
                    continue
                fi

                printf "  ${BLUE}[cargo]${NC} %s ... " "$pkg_name"
                if cargo install "$pkg_name" --quiet 2>/dev/null; then
                    local ver
                    ver=$(cargo install --list 2>/dev/null | grep "^${pkg_name} " | head -1 | sed 's/.* v//;s/:.*//')
                    local json
                    json=$(jq -n \
                        --arg name    "$pkg_name" \
                        --arg package "$pkg_name" \
                        --arg version "$ver" \
                        --arg added   "$(date -Iseconds)" \
                        '{name:$name,type:"cargo",package:$package,version:$version,status:"ok",added:$added}')
                    registry_write cargo "$safe_id" "$json"
                    printf "${GREEN}ok${NC}\n"
                    (( cargo_ok++ )) || true
                else
                    printf "${RED}FAILED${NC}\n"
                    (( cargo_fail++ )) || true
                fi
            done < <(jq -r '(.tools.cargo // [])[]' "$bundle_file")

            echo ""
            print_status "cargo: $cargo_ok installed, $cargo_skip skipped, $cargo_fail failed"
        fi
        echo ""
    fi

    # ── Phase 5: profile-aware terminal environment + dotfiles ─────
    # Yazi and lazydocker are general workflow tools, not profile choices.
    # The terminal, multiplexer, shell, framework, and user dotfiles are all
    # delegated to the profile engine so bundle replay cannot overwrite the
    # profile selected by install.sh or the CLI.
    _progress 96 "Phase 5: Applying terminal profile..."

    # Yazi + ya
    if ! command -v yazi >/dev/null 2>&1; then
        local YAZI_VER
        YAZI_VER=$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest | grep tag_name | cut -d'"' -f4 2>/dev/null)
        if [ -n "$YAZI_VER" ]; then
            curl -sL "https://github.com/sxyazi/yazi/releases/download/${YAZI_VER}/yazi-x86_64-unknown-linux-gnu.zip" -o /tmp/yazi.zip 2>/dev/null
            if (cd /tmp && unzip -oq yazi.zip && mv yazi-x86_64-unknown-linux-gnu/yazi /usr/local/bin/ && mv yazi-x86_64-unknown-linux-gnu/ya /usr/local/bin/) 2>/dev/null; then
                print_success "  yazi $YAZI_VER installed"
            else
                print_warning "  yazi install failed"
            fi
            rm -rf /tmp/yazi.zip /tmp/yazi-x86_64-unknown-linux-gnu
        fi
    fi

    # Lazydocker
    if ! command -v lazydocker >/dev/null 2>&1; then
        if curl -sL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash 2>/dev/null; then
            [ -f "$HOME/.local/bin/lazydocker" ] && cp "$HOME/.local/bin/lazydocker" /usr/local/bin/ 2>/dev/null
            command -v lazydocker >/dev/null 2>&1 && print_success "  lazydocker installed" || print_warning "  lazydocker not in PATH"
        else
            print_warning "  lazydocker download failed"
        fi
    fi

    if declare -F profile_apply >/dev/null 2>&1; then
        local active_profile
        active_profile=$(profile_resolve_name "${PORTALGUN_PROFILE:-}")
        print_status "Phase 5: terminal profile ($active_profile)"
        profile_apply "$active_profile"

        # Publish the selected profile's files for the web dotfile manager.
        local profile_dotfiles profile_web_dir first_user
        profile_dotfiles="$(profile_path "$active_profile")/$(jq -r '.dotfiles.source // "dotfiles"' "$(profile_file "$active_profile")")"
        profile_web_dir="/opt/tools-docs/dotfiles/profiles/$active_profile"
        first_user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-kali}}"
        if [ -d "$profile_dotfiles" ]; then
            mkdir -p "$profile_web_dir"
            rsync -a --delete "$profile_dotfiles/" "$profile_web_dir/"
            chown -R "$first_user:$first_user" "/opt/tools-docs/dotfiles/profiles" 2>/dev/null || true
        fi
    else
        print_error "Profile engine is missing; refusing to apply hard-coded dotfiles"
        return 1
    fi
    echo ""

    # ── Phase 6: Burp Pro + Sliver (heavy specialty installs) ──
    if [ "${PORTALGUN_SKIP_BURP:-0}" != "1" ]; then
        _progress 97 "Phase 6a: Burp Suite Pro + BApps..."
        print_status "Phase 6a: Burp Suite Pro"
        if source "$PORTALGUN_LIB/install_burp.sh" 2>/dev/null && install_burp_pro; then
            print_success "Burp Suite Pro installed"
        else
            print_warning "Burp Suite Pro install skipped/failed (non-fatal)"
        fi
    fi
    if [ "${PORTALGUN_SKIP_SLIVER:-0}" != "1" ]; then
        _progress 98 "Phase 6b: Sliver C2 + armory..."
        print_status "Phase 6b: Sliver C2"
        if source "$PORTALGUN_LIB/install_sliver.sh" 2>/dev/null && install_sliver; then
            print_success "Sliver installed"
        else
            print_warning "Sliver install skipped/failed (non-fatal)"
        fi
    fi

    # Auto-register all installed tools so web UI search is populated
    _progress 99 "Registering tools in registry..."
    print_status "Running portalgun register to populate search..."
    source "$PORTALGUN_LIB/register.sh"
    register_all 2>/dev/null | grep -E "registered|summary" || true

    source "$PORTALGUN_LIB/sync_web.sh"
    sync_web_manifest

    _progress 100 "Installation complete!"
    print_success "Done. Run 'portalgun status' to verify."
    # Emit refresh signal so web UI reloads tool list
    echo "REFRESH_MANIFEST"
}
