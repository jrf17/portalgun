#!/bin/bash
# portalgun → web UI sync
# Walks the registry and writes a single JSON manifest the web UI consumes.

sync_web_manifest() {
    local out_dir="$PORTALGUN_WEB_DIR"
    local out_file="$out_dir/portalgun_tools.json"

    if [ ! -d "$out_dir" ]; then
        print_warning "Web dir not present: $out_dir (web sync skipped)"
        return 0
    fi

    if ! python3 "$PORTALGUN_LIB/sync_web.py" "$PORTALGUN_REGISTRY" "$out_file"; then
        print_warning "Failed to write web manifest"
        return 1
    fi
    print_success "Updated web manifest → $out_file"

    if command -v systemctl >/dev/null 2>&1 &&
        systemctl is-active --quiet portalgun-p3ta-tricks.service 2>/dev/null
    then
        systemctl restart portalgun-p3ta-tricks.service 2>/dev/null ||
            print_warning "p3ta-tricks restart failed after web sync"
    fi
}
