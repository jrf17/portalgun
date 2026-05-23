#!/bin/bash
# portalgun github installer with auto-compile

install_github() {
    local url="$1"
    local target_dir="$2"

    if [ -z "$url" ]; then
        print_error "Usage: portalgun install github <url> [target-dir]"
        print_status "Example: portalgun install github https://github.com/akamai/BadSuccessor /opt/tools/windows/exploit"
        exit 1
    fi

    require_root install github "$url" "$target_dir"
    require_cmd git jq
    ensure_dirs

    # Parse URL → owner/repo
    local repo=$(echo "$url" | sed -E 's|https?://github\.com/||; s|\.git$||; s|/$||')
    if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        print_error "Could not parse owner/repo from URL: $url"
        exit 1
    fi
    local owner="${repo%%/*}"
    local repo_name="${repo##*/}"
    local id_name=$(echo "${owner}_${repo_name}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_')
    local short_name=$(echo "$repo_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-//; s/-$//')

    target_dir="${target_dir:-$PORTALGUN_TOOLS_BASE/misc}"
    local tool_dir="$target_dir/$short_name"
    local clone_dir="$tool_dir/source"

    print_status "Installing $repo"
    print_status "  Target:  $tool_dir"
    print_status "  Source:  $clone_dir"

    mkdir -p "$tool_dir"

    # Clone or update
    if [ -d "$clone_dir/.git" ]; then
        print_status "Updating existing clone..."
        if ! (cd "$clone_dir" && GIT_TERMINAL_PROMPT=0 git pull -q) 2>>"$PORTALGUN_LOG_DIR/git.log"; then
            print_warning "git pull failed; continuing with existing tree"
        fi
    else
        rm -rf "$clone_dir"
        print_status "Cloning..."
        if ! GIT_TERMINAL_PROMPT=0 git clone -q "$url" "$clone_dir" 2>>"$PORTALGUN_LOG_DIR/git.log"; then
            print_error "git clone failed; see $PORTALGUN_LOG_DIR/git.log"
            exit 1
        fi
    fi

    local commit=$(cd "$clone_dir" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Detect build system
    local detect_result=$(detect_build "$clone_dir")
    local lang="${detect_result%%|*}"
    local build_cmd="${detect_result#*|}"
    print_status "Detected build: $lang"

    # Build (or not)
    local status="source_only"
    local should_build=0
    if should_compile "$target_dir" "$lang"; then
        should_build=1
    fi

    if [ $should_build -eq 1 ]; then
        print_status "  Build cmd: $build_cmd"
        ensure_build_deps "$lang"
        local log="$PORTALGUN_LOG_DIR/build_${id_name}.log"
        : > "$log"
        if (cd "$clone_dir" && eval "$build_cmd") >>"$log" 2>&1; then
            print_success "Build succeeded"
            status="ok"
        else
            print_warning "Build failed — registering as build_failed (see $log)"
            status="build_failed"
        fi
    else
        if [ "$lang" = "none" ]; then
            print_status "No build system detected; treating as scripts/binaries"
            status="ok"
        else
            print_status "Target is windows/ — skipping compile (using as-is)"
            status="skipped"
        fi
    fi

    # Surface useful artifacts into tool_dir root
    # Windows binaries + PS scripts
    find "$clone_dir" -maxdepth 3 -type f \( -name "*.exe" -o -name "*.ps1" -o -name "*.bat" \) \
        -exec cp -n {} "$tool_dir/" \; 2>/dev/null || true
    # Linux scripts
    find "$clone_dir" -maxdepth 3 -type f \( -name "*.sh" -o -name "*.py" \) \
        -exec cp -n {} "$tool_dir/" \; 2>/dev/null || true
    # Compiled binaries (rust target/release, go output, etc.)
    if [ "$status" = "ok" ] && [ $should_build -eq 1 ]; then
        case "$lang" in
            rust)
                [ -d "$clone_dir/target/release" ] && \
                    find "$clone_dir/target/release" -maxdepth 1 -type f -executable -not -name "*.d" -not -name "*.rlib" \
                        -exec cp {} "$tool_dir/" \; 2>/dev/null || true
                ;;
            go)
                # Go build -o $name produces a binary in clone_dir
                [ -f "$clone_dir/$short_name" ] && cp "$clone_dir/$short_name" "$tool_dir/" 2>/dev/null || true
                # Also grab any other built binaries
                find "$clone_dir" -maxdepth 1 -type f -executable -not -name "*.go" -not -name "*.md" \
                    -exec cp {} "$tool_dir/" \; 2>/dev/null || true
                ;;
        esac
    fi

    # Make scripts executable in tool root
    find "$tool_dir" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) \
        -exec chmod +x {} \; 2>/dev/null || true

    # Categorize from target dir for v1 script entry
    local rel_target="${target_dir#$PORTALGUN_TOOLS_BASE/}"
    local os_field=$(echo "$rel_target" | cut -d/ -f1)
    local cat_field=$(echo "$rel_target" | cut -d/ -f2)
    [ -z "$cat_field" ] && cat_field="misc"

    # Auto-symlink Linux-runnable binaries to /usr/local/bin (skip windows targets)
    if [[ "$target_dir" != */windows/* ]]; then
        find "$tool_dir" -maxdepth 1 -type f \
            \( -executable -o -name "*.sh" -o -name "*.py" -o -name "*.pl" -o -name "*.rb" \) \
            ! -name "*.exe" ! -name "*.ps1" ! -name "*.bat" ! -name "*.dll" \
            ! -name "*.md" ! -name "*.txt" ! -name "LICENSE*" \
            ! -name "*.json" ! -name "*.yaml" ! -name "*.yml" ! -name "*.toml" \
            ! -name "Dockerfile" ! -name "Makefile" ! -name "*.csproj" ! -name "*.sln" \
            ! -name "*.png" ! -name "*.jpg" ! -name "*.gif" \
            2>/dev/null | while read f; do
            local bn=$(basename "$f")
            local sym="/usr/local/bin/$bn"
            # Don't shadow system commands
            if [ -e "/usr/bin/$bn" ] || [ -e "/bin/$bn" ] || \
               [ -e "/usr/sbin/$bn" ] || [ -e "/sbin/$bn" ]; then
                continue
            fi
            if [ -L "$sym" ] || [ ! -e "$sym" ]; then
                ln -sf "$f" "$sym"
                print_status "  symlinked → $sym"
            fi
        done
    fi

    # Write registry entry
    local json=$(jq -n \
        --arg name       "$short_name" \
        --arg id         "$id_name" \
        --arg repo       "$repo" \
        --arg url        "$url" \
        --arg target     "$target_dir" \
        --arg tool_dir   "$tool_dir" \
        --arg language   "$lang" \
        --arg build_cmd  "$build_cmd" \
        --arg commit     "$commit" \
        --arg status     "$status" \
        --arg os_field   "$os_field" \
        --arg cat_field  "$cat_field" \
        --arg added      "$(date -Iseconds)" \
        '{name:$name, type:"github", id:$id, repo:$repo, url:$url, target:$target, tool_dir:$tool_dir, language:$language, build_cmd:$build_cmd, commit:$commit, status:$status, os:$os_field, category:$cat_field, added:$added}')
    registry_write github "$id_name" "$json"
    print_success "Registered → $PORTALGUN_REGISTRY/github/$id_name.json"
    print_success "Status: $status"

    source "$PORTALGUN_LIB/sync_scripts.sh"
    source "$PORTALGUN_LIB/sync_web.sh"
    sync_github_to_script "$id_name"
    sync_web_manifest
}
