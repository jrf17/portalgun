#!/usr/bin/env bash
# Portalgun profile engine — terminal, multiplexer, shell, framework, and dotfiles.

PROFILE_STATE_FILE="${PORTALGUN_PROFILE_STATE:-/var/lib/portalgun/profile-state.json}"

declare -F print_status >/dev/null 2>&1 || print_status() { printf '[*] %s\n' "$*"; }
declare -F print_success >/dev/null 2>&1 || print_success() { printf '[+] %s\n' "$*"; }
declare -F print_warning >/dev/null 2>&1 || print_warning() { printf '[!] %s\n' "$*" >&2; }
declare -F print_error >/dev/null 2>&1 || print_error() { printf '[-] %s\n' "$*" >&2; }

_profile_repo_root() {
    if [ -n "${PORTALGUN_PROFILE_ROOT:-}" ] && [ -d "$PORTALGUN_PROFILE_ROOT" ]; then
        printf '%s\n' "$PORTALGUN_PROFILE_ROOT"
        return
    fi
    if [ -n "${PORTALGUN_REPO_DIR:-}" ] && [ -d "$PORTALGUN_REPO_DIR/profiles" ]; then
        printf '%s\n' "$PORTALGUN_REPO_DIR/profiles"
        return
    fi
    local source_root
    source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -d "$source_root/profiles" ]; then
        printf '%s\n' "$source_root/profiles"
        return
    fi
    printf '%s\n' "${PORTALGUN_ROOT:-/opt/portalgun}/profiles"
}

_profile_component_root() {
    if [ -n "${PORTALGUN_COMPONENT_ROOT:-}" ] && [ -d "$PORTALGUN_COMPONENT_ROOT" ]; then
        printf '%s\n' "$PORTALGUN_COMPONENT_ROOT"
        return
    fi
    local profile_root source_root
    profile_root="$(_profile_repo_root)"
    source_root="$(dirname "$profile_root")"
    printf '%s\n' "$source_root/components"
}

profile_path() {
    printf '%s/%s\n' "$(_profile_repo_root)" "$1"
}

profile_file() {
    printf '%s/profile.json\n' "$(profile_path "$1")"
}

profile_exists() {
    [ -f "$(profile_file "$1")" ]
}

profile_list() {
    local root dir file
    root="$(_profile_repo_root)"
    [ -d "$root" ] || return 0
    for dir in "$root"/*; do
        [ -d "$dir" ] || continue
        file="$dir/profile.json"
        [ -f "$file" ] || continue
        printf '%-18s %s\n' "$(basename "$dir")" "$(jq -r '.description // ""' "$file")"
    done
}

profile_show() {
    local name="${1:-}" file
    [ -n "$name" ] || { print_error "Profile name is required"; return 64; }
    file="$(profile_file "$name")"
    [ -f "$file" ] || { print_error "Profile not found: $name"; return 1; }
    jq . "$file"
}

profile_validate() {
    local name="${1:-}" file component_root error=0
    [ -n "$name" ] || { print_error "Profile name is required"; return 64; }
    file="$(profile_file "$name")"
    [ -f "$file" ] || { print_error "Profile not found: $name"; return 1; }
    jq empty "$file" >/dev/null 2>&1 || { print_error "Invalid JSON: $file"; return 1; }

    local schema declared terminal shell framework dot_strategy
    schema=$(jq -r '.schema_version // 0' "$file")
    declared=$(jq -r '.name // ""' "$file")
    terminal=$(jq -r '.terminal.provider // "none"' "$file")
    shell=$(jq -r '.shell.provider // "none"' "$file")
    framework=$(jq -r '.framework.provider // "none"' "$file")
    dot_strategy=$(jq -r '.dotfiles.strategy // "none"' "$file")

    [ "$schema" = "1" ] || { print_error "$name: unsupported schema_version '$schema'"; error=1; }
    [ "$declared" = "$name" ] || { print_error "$name: manifest name is '$declared'"; error=1; }

    case "$terminal" in kitty|ghostty|tilix|alacritty|none) ;; *) print_error "$name: unsupported terminal '$terminal'"; error=1;; esac
    case "$shell" in zsh|bash|fish|none) ;; *) print_error "$name: unsupported shell '$shell'"; error=1;; esac
    case "$framework" in oh-my-zsh|oh-my-bash|fisher|none) ;; *) print_error "$name: unsupported framework '$framework'"; error=1;; esac
    case "$dot_strategy" in copy|none) ;; *) print_error "$name: unsupported dotfile strategy '$dot_strategy'"; error=1;; esac

    [ "$framework" != "oh-my-zsh" ] || [ "$shell" = "zsh" ] || { print_error "$name: oh-my-zsh requires zsh"; error=1; }
    [ "$framework" != "oh-my-bash" ] || [ "$shell" = "bash" ] || { print_error "$name: oh-my-bash requires bash"; error=1; }
    [ "$framework" != "fisher" ] || [ "$shell" = "fish" ] || { print_error "$name: fisher requires fish"; error=1; }
    [ "$shell" != "none" ] || [ "$framework" = "none" ] || { print_error "$name: shell=none requires framework=none"; error=1; }

    while IFS= read -r mux; do
        case "$mux" in tmux|zellij) ;; *) print_error "$name: unsupported multiplexer '$mux'"; error=1;; esac
    done < <(jq -r '(.multiplexers // [])[]' "$file")

    component_root="$(_profile_component_root)"
    local category provider
    for category in terminals shells frameworks; do
        case "$category" in
            terminals) provider="$terminal" ;;
            shells) provider="$shell" ;;
            frameworks) provider="$framework" ;;
        esac
        [ -x "$component_root/$category/$provider.sh" ] || {
            print_error "$name: missing provider $component_root/$category/$provider.sh"
            error=1
        }
    done
    while IFS= read -r provider; do
        [ -x "$component_root/multiplexers/$provider.sh" ] || {
            print_error "$name: missing provider $component_root/multiplexers/$provider.sh"
            error=1
        }
    done < <(jq -r '(.multiplexers // [])[]' "$file")

    if [ "$dot_strategy" = "copy" ]; then
        local dot_source dot_dir resolved
        dot_source=$(jq -r '.dotfiles.source // "dotfiles"' "$file")
        [[ "$dot_source" != /* && "$dot_source" != *".."* ]] || {
            print_error "$name: dotfiles.source must be a relative path without '..'"
            error=1
        }
        dot_dir="$(profile_path "$name")/$dot_source"
        [ -d "$dot_dir" ] || { print_error "$name: dotfiles directory missing: $dot_dir"; error=1; }
        if [ -d "$dot_dir" ]; then
            while IFS= read -r link; do
                resolved=$(readlink -f "$link" 2>/dev/null || true)
                [[ "$resolved" == "$dot_dir"/* ]] || {
                    print_error "$name: symlink escapes profile: $link"
                    error=1
                }
            done < <(find "$dot_dir" -type l 2>/dev/null)
        fi
    fi

    [ "$error" -eq 0 ] || return 1
    print_success "Profile '$name' is valid"
}

profile_select_interactive() {
    local root choices=() dir file description choice
    root="$(_profile_repo_root)"
    for dir in "$root"/*; do
        [ -f "$dir/profile.json" ] && choices+=("$(basename "$dir")")
    done
    [ "${#choices[@]}" -gt 0 ] || { print_error "No profiles found under $root"; return 1; }
    echo "Available Portalgun profiles:" >&2
    local i=1 name
    for name in "${choices[@]}"; do
        file="$root/$name/profile.json"
        description=$(jq -r '.description // ""' "$file")
        printf '  %d) %-16s %s\n' "$i" "$name" "$description" >&2
        i=$((i + 1))
    done
    printf 'Select a profile [1]: ' >&2
    read -r choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#choices[@]}" ] || {
        print_error "Invalid profile selection"
        return 1
    }
    printf '%s\n' "${choices[$((choice - 1))]}"
}

profile_resolve_name() {
    local requested="${1:-${PORTALGUN_PROFILE:-}}"
    if [ -n "$requested" ]; then
        printf '%s\n' "$requested"
        return
    fi
    if [ -f "$PROFILE_STATE_FILE" ]; then
        requested=$(jq -r '.active_profile // empty' "$PROFILE_STATE_FILE" 2>/dev/null || true)
        if [ -n "$requested" ] && profile_exists "$requested"; then
            printf '%s\n' "$requested"
            return
        fi
    fi
    printf '%s\n' default
}

_profile_run_as() {
    local user="$1"; shift
    local home
    home="$(_profile_user_home "$user")"
    if [ "$(id -u)" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" env HOME="$home" USER="$user" LOGNAME="$user" "$@"
    else
        env HOME="$home" USER="$user" LOGNAME="$user" "$@"
    fi
}

_profile_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

_profile_user_home() {
    getent passwd "$1" | cut -d: -f6
}

_profile_component() {
    local category="$1" provider="$2" action="$3" user="$4" profile_json="$5"
    local script="$(_profile_component_root)/$category/$provider.sh"
    PORTALGUN_PROFILE_FILE="$profile_json" PORTALGUN_TARGET_USER="$user" "$script" "$action"
}

profile_install_helpers() {
    local file="$1" user="$2" home helper
    home="$(_profile_user_home "$user")"
    while IFS= read -r helper; do
        case "$helper" in
            fzf)
                if [ ! -d "$home/.fzf" ]; then
                    _profile_run_as "$user" git clone --depth 1 https://github.com/junegunn/fzf.git "$home/.fzf"
                    _profile_run_as "$user" "$home/.fzf/install" --all --no-bash --no-fish
                fi
                ;;
            zoxide)
                command -v zoxide >/dev/null 2>&1 || _profile_run_as "$user" bash -c 'curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash'
                ;;
            starship)
                command -v starship >/dev/null 2>&1 || _profile_sudo sh -c 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin'
                ;;
            yazi)
                if ! command -v yazi >/dev/null 2>&1; then
                    local arch asset url tmp
                    arch=$(uname -m)
                    case "$arch" in x86_64) asset='yazi-x86_64-unknown-linux-gnu.zip';; aarch64) asset='yazi-aarch64-unknown-linux-gnu.zip';; *) print_warning "Yazi unsupported architecture: $arch"; continue;; esac
                    url=$(curl -fsSL https://api.github.com/repos/sxyazi/yazi/releases/latest | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' | head -1)
                    [ -n "$url" ] || { print_warning "Yazi release asset not found"; continue; }
                    tmp=$(mktemp -d)
                    curl -fsSL "$url" -o "$tmp/yazi.zip" && unzip -q "$tmp/yazi.zip" -d "$tmp"
                    _profile_sudo install -m 0755 "$tmp"/*/yazi /usr/local/bin/yazi
                    _profile_sudo install -m 0755 "$tmp"/*/ya /usr/local/bin/ya
                    rm -rf "$tmp"
                fi
                ;;
            lazygit)
                if ! command -v lazygit >/dev/null 2>&1; then
                    local ver url tmp
                    ver=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | jq -r '.tag_name' | sed 's/^v//')
                    url="https://github.com/jesseduffield/lazygit/releases/download/v${ver}/lazygit_${ver}_Linux_x86_64.tar.gz"
                    tmp=$(mktemp -d)
                    curl -fsSL "$url" -o "$tmp/lazygit.tgz" && tar xzf "$tmp/lazygit.tgz" -C "$tmp" lazygit
                    _profile_sudo install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
                    rm -rf "$tmp"
                fi
                ;;
            tealdeer)
                if ! command -v tldr >/dev/null 2>&1; then
                    local tmp
                    tmp=$(mktemp)
                    curl -fsSL https://github.com/tealdeer-rs/tealdeer/releases/latest/download/tealdeer-linux-x86_64-musl -o "$tmp"
                    _profile_sudo install -m 0755 "$tmp" /usr/local/bin/tldr
                    rm -f "$tmp"
                fi
                ;;
            nerd-font)
                if [ ! -d "$home/.local/share/fonts/JetBrainsMono" ]; then
                    local tmp
                    tmp=$(mktemp -d)
                    curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip -o "$tmp/font.zip"
                    _profile_run_as "$user" mkdir -p "$home/.local/share/fonts/JetBrainsMono"
                    _profile_run_as "$user" unzip -q "$tmp/font.zip" -d "$home/.local/share/fonts/JetBrainsMono"
                    fc-cache -f >/dev/null 2>&1 || true
                    rm -rf "$tmp"
                fi
                ;;
        esac
    done < <(jq -r '(.helpers // [])[]' "$file")
}

profile_apply_dotfiles() {
    local name="$1" user="$2" file source strategy backup home profile_dir source_dir backup_dir
    file="$(profile_file "$name")"
    strategy=$(jq -r '.dotfiles.strategy // "none"' "$file")
    [ "$strategy" = "copy" ] || return 0
    source=$(jq -r '.dotfiles.source // "dotfiles"' "$file")
    backup=$(jq -r '.dotfiles.backup_existing // true' "$file")
    profile_dir="$(profile_path "$name")"
    source_dir="$profile_dir/$source"
    home="$(_profile_user_home "$user")"
    [ -d "$home" ] || { print_error "Home directory not found for $user"; return 1; }
    [ -d "$source_dir" ] || { print_error "Profile dotfiles not found: $source_dir"; return 1; }

    local rsync_args=(-a)
    if [ "$backup" = "true" ]; then
        backup_dir="$home/.local/state/portalgun/backups/$(date +%Y%m%d-%H%M%S)-$name"
        _profile_run_as "$user" mkdir -p "$backup_dir"
        rsync_args+=(--backup "--backup-dir=$backup_dir")
    fi
    _profile_sudo rsync "${rsync_args[@]}" --chown="$user:$user" "$source_dir/" "$home/"
}

profile_expand_targets() {
    local file="$1" current="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER:-kali}}}" target user
    while IFS= read -r target; do
        case "$target" in
            current) printf '%s\n' "$current" ;;
            root) printf '%s\n' root ;;
            all-interactive-users)
                while IFS=: read -r user _ uid _ _ _ shell; do
                    [ "$uid" -ge 1000 ] 2>/dev/null || continue
                    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
                    printf '%s\n' "$user"
                done < /etc/passwd
                ;;
            *) printf '%s\n' "$target" ;;
        esac
    done < <(jq -r '(.targets // ["current"])[]' "$file") | awk '!seen[$0]++'
}

profile_apply_user() {
    local name="$1" user="$2" file terminal shell framework provider pkg
    file="$(profile_file "$name")"
    terminal=$(jq -r '.terminal.provider // "none"' "$file")
    shell=$(jq -r '.shell.provider // "none"' "$file")
    framework=$(jq -r '.framework.provider // "none"' "$file")

    while IFS= read -r pkg; do
        [ -n "$pkg" ] && _profile_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
    done < <(jq -r '(.packages.apt // [])[]' "$file")

    _profile_component terminals "$terminal" install "$user" "$file"
    while IFS= read -r provider; do
        _profile_component multiplexers "$provider" install "$user" "$file"
    done < <(jq -r '(.multiplexers // [])[]' "$file")
    _profile_component shells "$shell" install "$user" "$file"
    _profile_component frameworks "$framework" install "$user" "$file"
    if ! profile_install_helpers "$file" "$user"; then
        print_warning "One or more optional profile helpers failed for $user"
    fi
    profile_apply_dotfiles "$name" "$user"
}

profile_record_state() {
    local name="$1" target_user="${2:-${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER:-kali}}}}" file hash tmp
    file="$(profile_file "$name")"
    hash=$( { sha256sum "$file"; find "$(profile_path "$name")/dotfiles" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum; } | sha256sum | awk '{print $1}')
    tmp=$(mktemp)
    jq -n \
        --arg active_profile "$name" \
        --arg target_user "$target_user" \
        --arg applied_at "$(date -Iseconds)" \
        --arg profile_hash "$hash" \
        --arg terminal "$(jq -r '.terminal.provider // "none"' "$file")" \
        --arg shell "$(jq -r '.shell.provider // "none"' "$file")" \
        --arg framework "$(jq -r '.framework.provider // "none"' "$file")" \
        --argjson multiplexers "$(jq -c '.multiplexers // []' "$file")" \
        '{active_profile:$active_profile,target_user:$target_user,applied_at:$applied_at,profile_hash:$profile_hash,terminal:$terminal,multiplexers:$multiplexers,shell:$shell,framework:$framework}' > "$tmp"
    _profile_sudo mkdir -p "$(dirname "$PROFILE_STATE_FILE")"
    _profile_sudo install -m 0644 "$tmp" "$PROFILE_STATE_FILE"
    rm -f "$tmp"
}

profile_apply() {
    local name="$1" only_user="${2:-}" file user
    profile_validate "$name" >/dev/null
    file="$(profile_file "$name")"
    if [ -n "$only_user" ]; then
        profile_apply_user "$name" "$only_user"
    else
        while IFS= read -r user; do
            id "$user" >/dev/null 2>&1 || { print_warning "Profile target user not found: $user"; continue; }
            profile_apply_user "$name" "$user"
        done < <(profile_expand_targets "$file")
    fi
    profile_record_state "$name" "${only_user:-${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER:-kali}}}}"
    print_success "Applied terminal profile: $name"
}

profile_configure_panel() {
    local name="$1" user="$2" file provider home launcher name_label exec_cmd icon comment
    file="$(profile_file "$name")"
    provider=$(jq -r '.terminal.provider // "none"' "$file")
    [ "$provider" != "none" ] || return 0
    home="$(_profile_user_home "$user")"
    launcher="$home/.config/xfce4/panel/launcher-7"
    [ -d "$launcher" ] || return 0
    case "$provider" in
        kitty) name_label=Kitty; exec_cmd=kitty; icon=kitty; comment='GPU-accelerated terminal' ;;
        ghostty) name_label=Ghostty; exec_cmd=ghostty; icon=ghostty; comment='Fast terminal emulator' ;;
        tilix) name_label=Tilix; exec_cmd=tilix; icon=com.gexperts.Tilix; comment='Tiling terminal emulator' ;;
        alacritty) name_label=Alacritty; exec_cmd=alacritty; icon=Alacritty; comment='GPU-accelerated terminal' ;;
    esac
    local desktop="$launcher/${provider}.desktop"
    cat > /tmp/portalgun-terminal.desktop <<EOF_DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=$name_label
Comment=$comment
Exec=$exec_cmd
Icon=$icon
Terminal=false
Categories=System;TerminalEmulator;
EOF_DESKTOP
    _profile_sudo install -o "$user" -g "$user" -m 0644 /tmp/portalgun-terminal.desktop "$desktop"
    rm -f /tmp/portalgun-terminal.desktop
    find "$launcher" -maxdepth 1 -name '*.desktop' ! -name "${provider}.desktop" -delete 2>/dev/null || true
}

profile_summary() {
    local name="$1" file
    file="$(profile_file "$name")"
    printf 'Profile: %s\n' "$name"
    printf '  Terminal:     %s\n' "$(jq -r 'if (.terminal.provider // "none")=="none" then "none (Kali default)" else .terminal.provider end' "$file")"
    printf '  Multiplexers: %s\n' "$(jq -r 'if (.multiplexers // [] | length)==0 then "none (Kali default)" else (.multiplexers|join(", ")) end' "$file")"
    printf '  Shell:        %s\n' "$(jq -r 'if (.shell.provider // "none")=="none" then "none (Kali default)" else .shell.provider end' "$file")"
    printf '  Framework:    %s\n' "$(jq -r 'if (.framework.provider // "none")=="none" then "none (Kali default)" else .framework.provider end' "$file")"
}

profile_current() {
    if [ ! -f "$PROFILE_STATE_FILE" ]; then
        print_warning "No active profile has been recorded"
        return 1
    fi
    jq . "$PROFILE_STATE_FILE"
}

profile_verify() {
    local name="${1:-$(profile_resolve_name)}" file user terminal shell framework failed=0
    file="$(profile_file "$name")"
    profile_validate "$name" >/dev/null || return 2
    user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-${USER:-kali}}}"
    terminal=$(jq -r '.terminal.provider // "none"' "$file")
    shell=$(jq -r '.shell.provider // "none"' "$file")
    framework=$(jq -r '.framework.provider // "none"' "$file")
    echo "Profile verification: $name"
    if _profile_component terminals "$terminal" verify "$user" "$file"; then echo "  [PASS] terminal: $terminal"; else echo "  [FAIL] terminal: $terminal"; failed=1; fi
    while IFS= read -r provider; do
        if _profile_component multiplexers "$provider" verify "$user" "$file"; then echo "  [PASS] multiplexer: $provider"; else echo "  [FAIL] multiplexer: $provider"; failed=1; fi
    done < <(jq -r '(.multiplexers // [])[]' "$file")
    if _profile_component shells "$shell" verify "$user" "$file"; then echo "  [PASS] shell: $shell"; else echo "  [FAIL] shell: $shell"; failed=1; fi
    if _profile_component frameworks "$framework" verify "$user" "$file"; then echo "  [PASS] framework: $framework"; else echo "  [FAIL] framework: $framework"; failed=1; fi
    [ "$failed" -eq 0 ]
}

profile_create() {
    local name="${1:-}" root dir terminal mux_choice shell framework targets
    [ -n "$name" ] || { print_error "Usage: portalgun profile create NAME"; return 64; }
    [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { print_error "Profile names may contain lowercase letters, numbers, dots, underscores, and hyphens"; return 1; }
    if [ -n "${PORTALGUN_REPO_DIR:-}" ] && [ -d "$PORTALGUN_REPO_DIR/profiles" ] && [ -w "$PORTALGUN_REPO_DIR/profiles" ]; then
        root="$PORTALGUN_REPO_DIR/profiles"
    else
        root="$(_profile_repo_root)"
    fi
    dir="$root/$name"
    [ ! -e "$dir" ] || { print_error "Profile already exists: $name"; return 1; }
    [ -t 0 ] || { print_error "Profile creation requires an interactive terminal"; return 1; }
    mkdir -p "$dir/dotfiles"
    echo "Terminal: 1) kitty 2) ghostty 3) tilix 4) alacritty 5) none"
    read -r -p 'Selection [5]: ' terminal; terminal=${terminal:-5}
    case "$terminal" in 1) terminal=kitty;; 2) terminal=ghostty;; 3) terminal=tilix;; 4) terminal=alacritty;; *) terminal=none;; esac
    echo "Multiplexer: 1) tmux 2) zellij 3) both 4) none"
    read -r -p 'Selection [4]: ' mux_choice; mux_choice=${mux_choice:-4}
    case "$mux_choice" in 1) mux_choice='["tmux"]';; 2) mux_choice='["zellij"]';; 3) mux_choice='["tmux","zellij"]';; *) mux_choice='[]';; esac
    echo "Shell: 1) zsh 2) bash 3) fish 4) none"
    read -r -p 'Selection [4]: ' shell; shell=${shell:-4}
    case "$shell" in 1) shell=zsh;; 2) shell=bash;; 3) shell=fish;; *) shell=none;; esac
    case "$shell" in
        zsh) echo "Framework: 1) oh-my-zsh 2) none"; read -r -p 'Selection [2]: ' framework; [ "$framework" = 1 ] && framework=oh-my-zsh || framework=none;;
        bash) echo "Framework: 1) oh-my-bash 2) none"; read -r -p 'Selection [2]: ' framework; [ "$framework" = 1 ] && framework=oh-my-bash || framework=none;;
        fish) echo "Framework: 1) fisher 2) none"; read -r -p 'Selection [2]: ' framework; [ "$framework" = 1 ] && framework=fisher || framework=none;;
        none) framework=none;;
    esac
    targets='["current"]'
    jq -n --arg name "$name" --arg terminal "$terminal" --arg shell "$shell" --arg framework "$framework" --argjson mux "$mux_choice" --argjson targets "$targets" \
      '{schema_version:1,name:$name,description:("User profile: "+$name),owner:$name,targets:$targets,terminal:{provider:$terminal},multiplexers:$mux,shell:{provider:$shell,set_as_default:($shell!="none")},framework:{provider:$framework,plugins:[],external_plugins:[]},helpers:[],packages:{apt:[]},dotfiles:{source:"dotfiles",strategy:"copy",backup_existing:true}}' > "$dir/profile.json"
    print_success "Created profile: $dir"
}

profile_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list) profile_list ;;
        show) profile_show "${1:-}" ;;
        validate) profile_validate "${1:-$(profile_resolve_name)}" ;;
        create) profile_create "${1:-}" ;;
        apply)
            [ "$(id -u)" -eq 0 ] || { print_error "Profile apply needs root. Try: sudo portalgun --profile NAME profile apply"; return 1; }
            profile_apply "${1:-$(profile_resolve_name)}"
            ;;
        current) profile_current ;;
        verify) profile_verify "${1:-$(profile_resolve_name)}" ;;
        *) print_error "Unknown profile command: $sub"; return 64 ;;
    esac
}
