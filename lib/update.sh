#!/bin/bash
# portalgun update — upgrade apt + pull/rebuild github + pip + cargo

update_all() {
    require_root update
    ensure_dirs

    local apt_ok=0 apt_fail=0
    local gh_updated=0 gh_skipped=0 gh_fail=0
    local pip_ok=0 pip_fail=0
    local cargo_ok=0 cargo_fail=0

    # Allow git to operate on repos cloned by root — scoped to tools dir only
    git config --global --add safe.directory "$PORTALGUN_TOOLS_BASE/*" 2>/dev/null || true

    # ── Phase 1: APT ─────────────────────────────────────────────────
    print_status "Phase 1: apt update + upgrade"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
        print_success "apt upgrade complete"
        apt_ok=1
    else
        print_error "apt upgrade had errors"
        apt_fail=1
    fi
    echo ""

    # ── Phase 2: GitHub tools ─────────────────────────────────────────
    print_status "Phase 2: github tools — pull + rebuild all cloned repos"

    local git_repos=()
    while IFS= read -r gitdir; do
        git_repos+=("$(dirname "$gitdir")")
    done < <(find "$PORTALGUN_TOOLS_BASE" -maxdepth 5 -name ".git" -type d 2>/dev/null | sort)

    if [ ${#git_repos[@]} -eq 0 ]; then
        print_warning "No cloned repos found under $PORTALGUN_TOOLS_BASE"
    else
        print_status "Found ${#git_repos[@]} repos"

        # Build O(1) registry index — avoid grep -rl per repo (O(n²))
        declare -A _reg_idx
        for _rf in "$PORTALGUN_REGISTRY/github/"*.json; do
            [ -f "$_rf" ] || continue
            local _td
            _td=$(jq -r '.tool_dir // ""' "$_rf" 2>/dev/null)
            [ -n "$_td" ] && _reg_idx["$_td"]="$_rf"
        done

        for src_dir in "${git_repos[@]}"; do
            local name old_commit build_cmd=""
            name=$(basename "$(dirname "$src_dir")")/$(basename "$src_dir")
            old_commit=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null | cut -c1-7)

            local tool_dir reg_file=""
            tool_dir=$(dirname "$src_dir")
            reg_file="${_reg_idx[$tool_dir]:-}"
            [ -n "$reg_file" ] && build_cmd=$(jq -r '.build_cmd // ""' "$reg_file")

            printf "  ${BLUE}[git]${NC}  %-35s ... " "$name"

            if ! git -C "$src_dir" fetch origin --quiet 2>/dev/null; then
                printf "${RED}fetch failed${NC}\n"
                (( gh_fail++ )) || true
                continue
            fi

            local remote_commit
            remote_commit=$(git -C "$src_dir" rev-parse origin/HEAD 2>/dev/null | cut -c1-7)

            if [ "$remote_commit" = "$old_commit" ]; then
                printf "${CYAN}up to date${NC} (%s)\n" "$old_commit"
                (( gh_skipped++ )) || true
                continue
            fi

            if ! git -C "$src_dir" pull --quiet 2>/dev/null; then
                # Try stash + pull if local changes are blocking
                if git -C "$src_dir" stash --quiet 2>/dev/null && git -C "$src_dir" pull --quiet 2>/dev/null; then
                    printf "${YELLOW}stashed+pulled${NC} "
                else
                    printf "${RED}pull failed${NC}\n"
                    (( gh_fail++ )) || true
                    continue
                fi
            fi

            local new_commit
            new_commit=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null | cut -c1-7)
            printf "${GREEN}%s → %s${NC}" "$old_commit" "$new_commit"

            # Re-detect build system in case it wasn't compiled before
            if [ -z "$build_cmd" ]; then
                source "$PORTALGUN_LIB/detect.sh"
                local detect_result
                detect_result=$(detect_build "$src_dir")
                local detected_lang="${detect_result%%|*}"
                build_cmd="${detect_result#*|}"
                local tool_dir_up
                tool_dir_up=$(dirname "$src_dir")
                if ! should_compile "$tool_dir_up" "$detected_lang"; then
                    build_cmd=""
                fi
            fi

            if [ -n "$build_cmd" ]; then
                printf " | building..."
                if (cd "$src_dir" && eval "$build_cmd" >/dev/null 2>&1); then
                    printf " ${GREEN}ok${NC}\n"
                else
                    printf " ${RED}build failed${NC}\n"
                    (( gh_fail++ )) || true
                fi
            else
                printf "\n"
            fi

            [ -n "$reg_file" ] && jq --arg c "$new_commit" '.commit = $c' "$reg_file" > "$reg_file.tmp" && mv "$reg_file.tmp" "$reg_file"
            (( gh_updated++ )) || true
        done
    fi
    echo ""

    # ── Phase 3: pip ─────────────────────────────────────────────────
    local VENV="/opt/pentest-venv"
    local pip_cmd
    if [ -f "$VENV/bin/pip" ]; then
        pip_cmd="$VENV/bin/pip"
    else
        pip_cmd=$(command -v pip3 || command -v pip || echo "")
    fi
    if [ -n "$pip_cmd" ]; then
        print_status "Phase 3: pip upgrade all"
        # pip list --outdated then upgrade each; --upgrade-all not supported natively
        local outdated_count=0
        local outdated_pkgs=()
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local pkg_name
            pkg_name=$(echo "$line" | awk '{print $1}')
            outdated_pkgs+=("$pkg_name")
            (( outdated_count++ )) || true
        done < <("$pip_cmd" list --outdated --format=columns 2>/dev/null | tail -n +3)

        if [ "$outdated_count" -eq 0 ]; then
            print_success "pip: all packages up to date"
            pip_ok=1
        else
            print_status "pip: $outdated_count outdated packages, upgrading..."
            if "$pip_cmd" install --quiet --upgrade "${outdated_pkgs[@]}" 2>&1 | tail -3; then
                print_success "pip: $outdated_count packages upgraded"
                pip_ok=1
                # Update registry versions for upgraded packages
                for pkg_name in "${outdated_pkgs[@]}"; do
                    local new_ver safe_id
                    new_ver=$("$pip_cmd" show "$pkg_name" 2>/dev/null | awk '/^Version:/{print $2}')
                    safe_id=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')
                    local reg_file="$PORTALGUN_REGISTRY/pip/${safe_id}.json"
                    if [ -f "$reg_file" ] && [ -n "$new_ver" ]; then
                        jq --arg v "$new_ver" --arg p "${pkg_name}==${new_ver}" \
                            '.version = $v | .package = $p' "$reg_file" > "$reg_file.tmp" && mv "$reg_file.tmp" "$reg_file"
                    fi
                done
            else
                print_error "pip upgrade had errors"
                pip_fail=1
            fi
        fi
    else
        print_warning "pip not found — skipping"
    fi
    echo ""

    # ── Phase 4: cargo ───────────────────────────────────────────────
    if command -v cargo >/dev/null 2>&1; then
        print_status "Phase 4: cargo tools"
        if ! cargo install-update --version >/dev/null 2>&1; then
            print_status "Installing cargo-update..."
            cargo install cargo-update --quiet 2>&1 | tail -1
        fi
        if cargo install-update --all 2>&1; then
            print_success "cargo tools updated"
            cargo_ok=1
        else
            print_error "cargo update had errors"
            cargo_fail=1
        fi
    else
        print_warning "cargo not found — skipping"
    fi
    echo ""

    print_status "Update summary:"
    echo "  apt:    $([ $apt_ok -eq 1 ] && echo 'upgraded' || echo 'failed')"
    echo "  github: $gh_updated updated, $gh_skipped up-to-date, $gh_fail failed"
    echo "  pip:    $([ $pip_ok -eq 1 ] && echo 'updated' || ([ -n "$pip_cmd" ] && echo 'failed' || echo 'not installed'))"
    echo "  cargo:  $([ $cargo_ok -eq 1 ] && echo 'updated' || (command -v cargo >/dev/null 2>&1 && echo 'failed' || echo 'not installed'))"
    echo ""

    source "$PORTALGUN_LIB/sync_web.sh"
    sync_web_manifest
    print_success "Web manifest refreshed"
}
