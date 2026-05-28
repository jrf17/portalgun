#!/bin/bash
# portalgun export — dump registry to a single bundle JSON

export_bundle() {
    local outfile="${1:-portalgun_bundle.json}"
    ensure_dirs

    local apt_entries="[]"
    local github_entries="[]"
    local pip_entries="[]"
    local cargo_entries="[]"

    # Collect apt entries
    for f in "$PORTALGUN_REGISTRY/apt"/*.json; do
        [ -f "$f" ] || continue
        apt_entries=$(echo "$apt_entries" | jq --argjson e "$(cat "$f")" '. + [$e.package // $e.name]')
    done

    # Collect github entries
    for f in "$PORTALGUN_REGISTRY/github"/*.json; do
        [ -f "$f" ] || continue
        local url target
        url=$(jq -r '.url // ""' "$f")
        target=$(jq -r '.target // ""' "$f")
        [ -z "$url" ] && continue
        github_entries=$(echo "$github_entries" | jq \
            --arg url "$url" \
            --arg target "$target" \
            '. + [{"url": $url, "target": $target}]')
    done

    # Collect pip entries (stored as "name==version")
    if [ -d "$PORTALGUN_REGISTRY/pip" ]; then
        for f in "$PORTALGUN_REGISTRY/pip"/*.json; do
            [ -f "$f" ] || continue
            pip_entries=$(echo "$pip_entries" | jq --argjson e "$(cat "$f")" '. + [$e.package // $e.name]')
        done
    fi

    # Collect cargo entries (just package names)
    if [ -d "$PORTALGUN_REGISTRY/cargo" ]; then
        for f in "$PORTALGUN_REGISTRY/cargo"/*.json; do
            [ -f "$f" ] || continue
            cargo_entries=$(echo "$cargo_entries" | jq --argjson e "$(cat "$f")" '. + [$e.package // $e.name]')
        done
    fi

    local bundle
    bundle=$(jq -n \
        --arg version "2" \
        --arg exported_at "$(date -Iseconds)" \
        --argjson apt    "$apt_entries" \
        --argjson github "$github_entries" \
        --argjson pip    "$pip_entries" \
        --argjson cargo  "$cargo_entries" \
        '{version: $version, exported_at: $exported_at,
          tools: {apt: $apt, github: $github, pip: $pip, cargo: $cargo}}')

    if [ "$outfile" = "-" ]; then
        echo "$bundle"
    else
        echo "$bundle" > "$outfile"
        local apt_count github_count pip_count cargo_count
        apt_count=$(echo "$apt_entries"    | jq 'length')
        github_count=$(echo "$github_entries" | jq 'length')
        pip_count=$(echo "$pip_entries"    | jq 'length')
        cargo_count=$(echo "$cargo_entries"  | jq 'length')
        print_success "Exported: $apt_count apt, $github_count github, $pip_count pip, $cargo_count cargo → $outfile"
    fi
}
