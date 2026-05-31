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
            registry_exists apt "$pkg" || apt_needed+=("$pkg")
        done < <(jq -r '.tools.apt[]' "$bundle_file")

        local apt_skip=$(( apt_count - ${#apt_needed[@]} ))
        local apt_total=${#apt_needed[@]}
        print_status "  $apt_skip already installed, $apt_total to install"

        if [ "$apt_total" -gt 0 ]; then
            _progress 2 "Phase 1: Downloading apt packages ($apt_total)..."
            local apt_done=0
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_needed[@]}" 2>&1 | \
                while IFS= read -r line; do
                    if echo "$line" | grep -qE "^Setting up|^Unpacking"; then
                        local pkg_name
                        # "Setting up nmap (1.2.3)..." or "Unpacking nmap (1.2.3)..."
                        pkg_name=$(echo "$line" | sed 's/^Setting up //;s/^Unpacking //' | grep -oE '^[a-z][a-z0-9.+_-]+')
                        apt_done=$(( apt_done + 1 ))
                        # apt occupies 2–34% — cap at total to avoid overflow
                        local display_done=$(( apt_done > apt_total ? apt_total : apt_done ))
                        local pct=$(( 2 + ( display_done * 32 / apt_total ) ))
                        [ "$pct" -gt 34 ] && pct=34
                        _progress "$pct" "Phase 1: apt [$display_done/$apt_total] $pkg_name"
                        printf "  ${BLUE}[apt]${NC} [%d/%d] %s\n" "$display_done" "$apt_total" "$pkg_name"
                    fi
                done

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

            if registry_exists github "${name}_"; then
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

        # Write requirements.txt and install all at once
        # pip resolves the full dependency graph together — no batching conflicts
        local req_file
        req_file=$(mktemp /tmp/portalgun_req_XXXXXX.txt)
        jq -r '(.tools.pip // [])[]' "$bundle_file" > "$req_file"
        local pip_total
        pip_total=$(wc -l < "$req_file")

        print_status "  Installing $pip_total packages via requirements.txt..."
        _progress 82 "Phase 3: pip — resolving and installing $pip_total packages..."

        "$VENV_PIP" install --quiet -r "$req_file" 2>&1 | \
            grep -E "^ERROR|× Failed|Cannot install|Failed to build|ResolutionImpossible" | \
            grep -v "dependency resolver does not currently" || true

        rm -f "$req_file"

        # Register all pip packages
        while IFS= read -r pkg_spec; do
            [ -z "$pkg_spec" ] && continue
            local pkg_name pkg_ver safe_id
            pkg_name=$(echo "$pkg_spec" | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            pkg_ver=$(echo "$pkg_spec" | cut -d= -f3)
            safe_id=$(echo "$pkg_name" | tr -cs 'a-z0-9._-' '_')
            if ! registry_exists pip "$safe_id"; then
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
                if cargo install "$pkg_name" --quiet 2>/dev/null || true; then
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

    source "$PORTALGUN_LIB/sync_web.sh"
    sync_web_manifest

    _progress 100 "Installation complete!"
    print_success "Done. Run 'portalgun status' to verify."
}
