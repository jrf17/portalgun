#!/bin/bash
# portalgun registry — read/write per-tool JSON manifests

registry_write() {
    local type="$1"   # apt | github
    local name="$2"   # filename without .json
    local json="$3"
    ensure_dirs
    echo "$json" | jq '.' > "$PORTALGUN_REGISTRY/$type/$name.json"
}

registry_read() {
    local type="$1"
    local name="$2"
    cat "$PORTALGUN_REGISTRY/$type/$name.json" 2>/dev/null
}

registry_exists() {
    local type="$1"
    local name="$2"
    [ -f "$PORTALGUN_REGISTRY/$type/$name.json" ]
}

registry_list() {
    local filter="${1:-all}"
    ensure_dirs

    local types=()
    case "$filter" in
        all)    types=(apt github pip cargo) ;;
        apt)    types=(apt) ;;
        github) types=(github) ;;
        pip)    types=(pip) ;;
        cargo)  types=(cargo) ;;
        *)      print_error "Unknown filter: $filter (use: all, apt, github, pip, cargo)"; exit 1 ;;
    esac

    for type in "${types[@]}"; do
        echo ""
        echo "─── $type ───────────────────────────────────────────"
        local found=0
        for f in "$PORTALGUN_REGISTRY/$type"/*.json; do
            [ -f "$f" ] || continue
            found=1
            local name=$(jq -r '.name // "?"' "$f")
            local version=$(jq -r '.version // .commit // "?"' "$f")
            local status=$(jq -r '.status // "ok"' "$f")
            local target=$(jq -r '.target // .package // "?"' "$f")
            local color="$GREEN"
            [ "$status" = "build_failed" ] && color="$YELLOW"
            [ "$status" = "skipped" ] && color="$CYAN"
            printf "  ${color}%-25s${NC} %-15s %s\n" "$name" "$version" "$target"
        done
        [ $found -eq 0 ] && echo "  (none)"
    done
    echo ""
}

registry_status() {
    ensure_dirs
    local apt_count=$(find "$PORTALGUN_REGISTRY/apt"    -name "*.json" 2>/dev/null | wc -l)
    local github_count=$(find "$PORTALGUN_REGISTRY/github" -name "*.json" 2>/dev/null | wc -l)
    local pip_count=$(find "$PORTALGUN_REGISTRY/pip"    -name "*.json" 2>/dev/null | wc -l)
    local cargo_count=$(find "$PORTALGUN_REGISTRY/cargo"  -name "*.json" 2>/dev/null | wc -l)
    local build_failed=$(grep -l '"status": "build_failed"' "$PORTALGUN_REGISTRY"/github/*.json 2>/dev/null | wc -l)
    echo ""
    echo "Registry:        $PORTALGUN_REGISTRY"
    echo "  apt tools:     $apt_count"
    echo "  github tools:  $github_count (build_failed: $build_failed)"
    echo "  pip packages:  $pip_count"
    echo "  cargo tools:   $cargo_count"
    echo "  total:         $((apt_count + github_count + pip_count + cargo_count))"
    echo ""
    echo "Web manifest:    $PORTALGUN_WEB_DIR/portalgun_tools.json"
    echo "Repo dir:        $PORTALGUN_REPO_DIR"
    [ -f "$PORTALGUN_REPO_DIR/data/installable_packages.txt" ] \
        && echo "  data/installable_packages.txt: present" \
        || echo "  data/installable_packages.txt: MISSING (apt syncs to script skipped)"
    [ -f "$PORTALGUN_REPO_DIR/installers/install_github_tools.sh" ] \
        && echo "  installers/install_github_tools.sh: present" \
        || echo "  installers/install_github_tools.sh: MISSING (github syncs to script skipped)"
    echo ""
}
