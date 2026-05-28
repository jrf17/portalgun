#!/bin/bash
# portalgun apply — install all tools from a bundle JSON

apply_bundle() {
    local bundle_file="${1:-}"

    # Find default bundle if not specified
    if [ -z "$bundle_file" ]; then
        for candidate in \
            "$PORTALGUN_REPO_DIR/portalgun_bundle.json" \
            "$PORTALGUN_REPO_DIR/data/portalgun_bundle.json" \
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
    apt_count=$(jq '.tools.apt | length'    "$bundle_file")
    github_count=$(jq '.tools.github | length' "$bundle_file")
    pip_count=$(jq '(.tools.pip // []) | length'   "$bundle_file")
    cargo_count=$(jq '(.tools.cargo // []) | length' "$bundle_file")

    print_status "Applying bundle (v${version}): $apt_count apt, $github_count github, $pip_count pip, $cargo_count cargo"
    echo ""

    # ── APT ──────────────────────────────────────────────────────────
    if [ "$apt_count" -gt 0 ]; then
        print_status "Phase 1: apt packages ($apt_count)"

        # Batch install: collect all packages not in registry, install in one apt call
        local apt_needed=()
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if registry_exists apt "$pkg"; then
                continue
            fi
            apt_needed+=("$pkg")
        done < <(jq -r '.tools.apt[]' "$bundle_file")

        local apt_skip=$(( apt_count - ${#apt_needed[@]} ))
        print_status "  $apt_skip already installed, ${#apt_needed[@]} to install"

        if [ ${#apt_needed[@]} -gt 0 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_needed[@]}" 2>&1 | tail -5
            # Register newly installed ones
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
                        '{name:$name, type:"apt", package:$package, version:$version, status:"ok", added:$added}')
                    registry_write apt "$pkg" "$json"
                fi
            done
        fi

        print_status "apt phase complete"
        echo ""
    fi

    # ── GitHub ───────────────────────────────────────────────────────
    if [ "$github_count" -gt 0 ]; then
        print_status "Phase 2: github tools ($github_count)"
        local gh_ok=0 gh_skip=0 gh_fail=0

        while IFS= read -r entry; do
            local url target name
            url=$(echo "$entry" | jq -r '.url')
            target=$(echo "$entry" | jq -r '.target // "/opt/tools/misc"')
            name=$(basename "$url" .git | tr '[:upper:]' '[:lower:]')

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

        echo ""
        print_status "github: $gh_ok installed, $gh_skip skipped, $gh_fail failed"
        echo ""
    fi

    # ── pip ──────────────────────────────────────────────────────────
    if [ "$pip_count" -gt 0 ]; then
        print_status "Phase 3: pip packages ($pip_count)"

        local pip_cmd
        pip_cmd=$(command -v pip3 || command -v pip || echo "")
        if [ -z "$pip_cmd" ]; then
            print_warning "pip not found — skipping pip phase"
        else
            local pip_needed=()
            while IFS= read -r pkg_spec; do
                [ -z "$pkg_spec" ] && continue
                local pkg_name
                pkg_name=$(echo "$pkg_spec" | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                local safe_id
                safe_id=$(echo "$pkg_name" | tr -cs 'a-z0-9._-' '_')
                if registry_exists pip "$safe_id"; then
                    continue
                fi
                pip_needed+=("$pkg_spec")
            done < <(jq -r '(.tools.pip // [])[]' "$bundle_file")

            local pip_skip=$(( pip_count - ${#pip_needed[@]} ))
            print_status "  $pip_skip already installed, ${#pip_needed[@]} to install"

            if [ ${#pip_needed[@]} -gt 0 ]; then
                # Install in batches of 50 to avoid arg list limits
                local batch=()
                local batch_num=0
                for pkg_spec in "${pip_needed[@]}"; do
                    batch+=("$pkg_spec")
                    if [ ${#batch[@]} -ge 50 ]; then
                        (( batch_num++ )) || true
                        printf "  Installing pip batch %d...\n" "$batch_num"
                        "$pip_cmd" install --quiet --break-system-packages "${batch[@]}" 2>&1 | tail -2
                        batch=()
                    fi
                done
                if [ ${#batch[@]} -gt 0 ]; then
                    (( batch_num++ )) || true
                    printf "  Installing pip batch %d...\n" "$batch_num"
                    "$pip_cmd" install --quiet --break-system-packages "${batch[@]}" 2>&1 | tail -2
                fi

                # Register installed pip packages
                while IFS= read -r pkg_spec; do
                    [ -z "$pkg_spec" ] && continue
                    local pkg_name pkg_ver
                    pkg_name=$(echo "$pkg_spec" | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                    pkg_ver=$(echo "$pkg_spec" | cut -d= -f3)
                    local safe_id
                    safe_id=$(echo "$pkg_name" | tr -cs 'a-z0-9._-' '_')
                    if ! registry_exists pip "$safe_id"; then
                        local json
                        json=$(jq -n \
                            --arg name    "$pkg_name" \
                            --arg package "$pkg_spec" \
                            --arg version "$pkg_ver" \
                            --arg added   "$(date -Iseconds)" \
                            '{name:$name, type:"pip", package:$package, version:$version, status:"ok", added:$added}')
                        registry_write pip "$safe_id" "$json"
                    fi
                done < <(jq -r '(.tools.pip // [])[]' "$bundle_file")
            fi
        fi

        print_status "pip phase complete"
        echo ""
    fi

    # ── cargo ────────────────────────────────────────────────────────
    if [ "$cargo_count" -gt 0 ]; then
        print_status "Phase 4: cargo packages ($cargo_count)"

        if ! command -v cargo >/dev/null 2>&1; then
            print_warning "cargo not found — skipping cargo phase"
        else
            local cargo_ok=0 cargo_skip=0 cargo_fail=0

            while IFS= read -r pkg_name; do
                [ -z "$pkg_name" ] && continue
                local safe_id
                safe_id=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')

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
                        '{name:$name, type:"cargo", package:$package, version:$version, status:"ok", added:$added}')
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

    # Sync web manifest
    source "$PORTALGUN_LIB/sync_web.sh"
    sync_web_manifest

    print_success "Done. Run 'portalgun status' to verify."
}
