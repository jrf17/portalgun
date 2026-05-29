#!/bin/bash
# portalgun register — backfill registry from currently installed state

register_all() {
    require_root register
    ensure_dirs

    mkdir -p "$PORTALGUN_REGISTRY/apt" "$PORTALGUN_REGISTRY/github" \
             "$PORTALGUN_REGISTRY/pip" "$PORTALGUN_REGISTRY/cargo"

    local apt_added=0 apt_skipped=0 apt_missing=0

    # ── APT: walk installable_packages.txt ───────────────────────────
    local pkg_list="$PORTALGUN_REPO_DIR/data/installable_packages.txt"
    if [ ! -f "$pkg_list" ]; then
        print_error "Package list not found: $pkg_list"
        exit 1
    fi

    local total
    total=$(wc -l < "$pkg_list")
    print_status "Scanning $total packages from installable_packages.txt..."
    echo ""

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue

        if registry_exists apt "$pkg"; then
            (( apt_skipped++ )) || true
            continue
        fi

        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            (( apt_missing++ )) || true
            continue
        fi

        local version
        version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "unknown")
        local json
        json=$(jq -n \
            --arg name    "$pkg" \
            --arg package "$pkg" \
            --arg version "$version" \
            --arg added   "$(date -Iseconds)" \
            '{name:$name, type:"apt", package:$package, version:$version, status:"ok", added:$added}')
        registry_write apt "$pkg" "$json"
        printf "  ${GREEN}[reg]${NC} %s (%s)\n" "$pkg" "$version"
        (( apt_added++ )) || true

    done < "$pkg_list"

    echo ""
    print_status "apt register summary: $apt_added registered, $apt_skipped already in registry, $apt_missing not installed"
    echo ""

    # ── GitHub: walk /opt/tools source dirs ──────────────────────────
    local gh_added=0 gh_skipped=0

    print_status "Scanning cloned repos under $PORTALGUN_TOOLS_BASE..."

    while IFS= read -r gitdir; do
        local src_dir
        src_dir=$(dirname "$gitdir")
        local tool_dir
        tool_dir=$(dirname "$src_dir")
        local name
        name=$(basename "$tool_dir" | tr '[:upper:]' '[:lower:]' | tr ' -' '__')
        local repo_slug
        repo_slug=$(git -C "$src_dir" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||;s|/|_|g' | tr '[:upper:]' '[:lower:]')
        local reg_id="${repo_slug}_"

        if registry_exists github "$reg_id"; then
            (( gh_skipped++ )) || true
            continue
        fi

        local url commit
        url=$(git -C "$src_dir" remote get-url origin 2>/dev/null || echo "")
        commit=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null | cut -c1-7 || echo "")
        local target
        target=$(dirname "$tool_dir")

        [ -z "$url" ] && continue

        local repo
        repo=$(echo "$url" | sed 's|.*github.com[:/]||;s|\.git$||')

        local json
        json=$(jq -n \
            --arg name     "$name" \
            --arg id       "$reg_id" \
            --arg repo     "$repo" \
            --arg url      "$url" \
            --arg target   "$target" \
            --arg tool_dir "$tool_dir" \
            --arg commit   "$commit" \
            --arg added    "$(date -Iseconds)" \
            '{name:$name, type:"github", id:$id, repo:$repo, url:$url,
              target:$target, tool_dir:$tool_dir, language:"unknown",
              build_cmd:"", commit:$commit, status:"ok", added:$added}')
        registry_write github "$reg_id" "$json"
        printf "  ${GREEN}[reg]${NC} %s (%s)\n" "$name" "$commit"
        (( gh_added++ )) || true

    done < <(find "$PORTALGUN_TOOLS_BASE" -maxdepth 5 -name ".git" -type d 2>/dev/null | sort)

    echo ""
    print_status "github register summary: $gh_added registered, $gh_skipped already in registry"
    echo ""

    # ── pip: snapshot all installed pip packages ──────────────────────
    local pip_added=0 pip_skipped=0

    if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
        local pip_cmd
        pip_cmd=$(command -v pip3 || command -v pip)
        print_status "Scanning pip packages (excluding debian/system packages)..."

        # Only include packages installed by pip, not by debian apt
        # Debian packages live in /usr/lib/python3/dist-packages — exclude those
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local pkg_name pkg_ver
            pkg_name=$(echo "$line" | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            pkg_ver=$(echo "$line" | cut -d= -f3)

            # Skip packages with no version (editable installs etc)
            [ -z "$pkg_ver" ] && continue

            # Skip if installed into debian system path (not a real pip install)
            local pkg_loc
            pkg_loc=$("$pip_cmd" show "$pkg_name" 2>/dev/null | grep "^Location:" | awk '{print $2}')
            if echo "$pkg_loc" | grep -q "/usr/lib/python3/dist-packages\|/usr/lib/python3/"; then
                continue
            fi

            local safe_id
            safe_id=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')

            if registry_exists pip "$safe_id"; then
                (( pip_skipped++ )) || true
                continue
            fi

            local json
            json=$(jq -n \
                --arg name    "$pkg_name" \
                --arg package "$pkg_name==$pkg_ver" \
                --arg version "$pkg_ver" \
                --arg added   "$(date -Iseconds)" \
                '{name:$name, type:"pip", package:$package, version:$version, status:"ok", added:$added}')
            registry_write pip "$safe_id" "$json"
            (( pip_added++ )) || true

        done < <("$pip_cmd" list --format=freeze 2>/dev/null)

        print_status "pip register summary: $pip_added registered, $pip_skipped already in registry"
        echo ""
    else
        print_warning "pip not found — skipping pip registration"
        echo ""
    fi

    # ── cargo: snapshot installed cargo binaries ──────────────────────
    local cargo_added=0 cargo_skipped=0

    if command -v cargo >/dev/null 2>&1; then
        print_status "Scanning cargo packages..."

        local current_pkg=""
        while IFS= read -r line; do
            # Lines look like: "feroxbuster v2.10.4:"
            if [[ "$line" =~ ^([a-zA-Z0-9_-]+)\ v([0-9][^:]+): ]]; then
                current_pkg="${BASH_REMATCH[1]}"
                local pkg_ver="${BASH_REMATCH[2]}"
                local safe_id
                safe_id=$(echo "$current_pkg" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')

                if registry_exists cargo "$safe_id"; then
                    (( cargo_skipped++ )) || true
                    continue
                fi

                local json
                json=$(jq -n \
                    --arg name    "$current_pkg" \
                    --arg package "$current_pkg" \
                    --arg version "$pkg_ver" \
                    --arg added   "$(date -Iseconds)" \
                    '{name:$name, type:"cargo", package:$package, version:$version, status:"ok", added:$added}')
                registry_write cargo "$safe_id" "$json"
                printf "  ${GREEN}[reg]${NC} %s (%s)\n" "$current_pkg" "$pkg_ver"
                (( cargo_added++ )) || true
            fi
        done < <(cargo install --list 2>/dev/null)

        print_status "cargo register summary: $cargo_added registered, $cargo_skipped already in registry"
        echo ""
    else
        print_warning "cargo not found — skipping cargo registration"
        echo ""
    fi

    # Sync web manifest
    source "$PORTALGUN_LIB/sync_web.sh"
    sync_web_manifest
    print_success "Registry backfill complete. Run 'portalgun export' to generate an updated bundle."
}
