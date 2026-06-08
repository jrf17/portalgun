# ═══════════════════════════════════════════════════════════════════
# ZSH CONFIGURATION - Kali Linux
# ═══════════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────────
# PATH CONFIGURATION (must be first)
# ───────────────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/.fzf/bin:$PATH"

# ───────────────────────────────────────────────────────────────────
# OH-MY-ZSH SETTINGS
# ───────────────────────────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"

plugins=(
    git
    zsh-syntax-highlighting
    zsh-autosuggestions
    fzf
    sudo
    command-not-found
)

source $ZSH/oh-my-zsh.sh

# ───────────────────────────────────────────────────────────────────
# HISTORY CONFIGURATION
# ───────────────────────────────────────────────────────────────────
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY          # Share history between all sessions
setopt INC_APPEND_HISTORY     # Write to history immediately
setopt EXTENDED_HISTORY       # Record timestamp of command
setopt HIST_IGNORE_DUPS       # Ignore duplicate commands
setopt HIST_IGNORE_ALL_DUPS   # Delete older duplicate entry
setopt HIST_FIND_NO_DUPS      # Do not display duplicates in search
setopt HIST_REDUCE_BLANKS     # Remove superfluous blanks
setopt HIST_VERIFY            # Show command before executing from history

# ───────────────────────────────────────────────────────────────────
# TERMINAL & EDITOR
# ───────────────────────────────────────────────────────────────────
export TERM=xterm-256color
export COLORTERM=truecolor
export EDITOR="nvim"

# ───────────────────────────────────────────────────────────────────
# PROMPT - Starship
# ───────────────────────────────────────────────────────────────────
eval "$(starship init zsh)"

# ───────────────────────────────────────────────────────────────────
# MODERN CLI TOOLS
# ───────────────────────────────────────────────────────────────────

# Zoxide (better cd)
eval "$(zoxide init zsh --cmd cd)"

# Bat - Tokyo Night theme
export BAT_THEME="TwoDark"

# FZF - Tokyo Night theme
export FZF_DEFAULT_OPTS="--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc --color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8 --height=40% --layout=reverse --border"
export FZF_DEFAULT_COMMAND="fdfind --type f --hidden --follow --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fdfind --type d --hidden --follow --exclude .git"

# Eza colors
export EZA_COLORS="da=1;34:gm=1;34"

# Source fzf
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# ───────────────────────────────────────────────────────────────────
# ALIASES - FILE OPERATIONS
# ───────────────────────────────────────────────────────────────────

# Navigation
alias home="cd ~"
alias ..="cd .."
alias ...="cd ../.."

# File listing (eza)
alias ls="eza --icons --group-directories-first"
alias ll="eza --icons --group-directories-first -l"
alias la="eza --icons --group-directories-first -la"
alias lt="eza --icons --group-directories-first --tree"
alias l="eza --icons --group-directories-first -F"

# File viewing (bat)
alias cat="batcat --style=plain --paging=never"
alias catp="batcat --style=full"

# Better replacements
alias top="btop"
alias find="fdfind"
alias grep="rg"

# ───────────────────────────────────────────────────────────────────
# ALIASES - GIT
# ───────────────────────────────────────────────────────────────────
alias lg="lazygit"
alias gs="git status"
alias ga="git add"
alias gc="git commit"
alias gp="git push"
alias gl="git pull"
alias gd="git diff"

# ───────────────────────────────────────────────────────────────────
# ALIASES - UTILITIES
# ───────────────────────────────────────────────────────────────────
alias zsource="source ~/.zshrc"
alias zconfig="nvim ~/.zshrc"
alias nconfig="nvim ~/.config/nvim"
alias h="history"
alias help="tldr"
alias ports="netstat -tulanp"
alias y="yazi"

# ───────────────────────────────────────────────────────────────────
# FUNCTIONS
# ───────────────────────────────────────────────────────────────────

# Quick directory navigation
mkcd() {
    mkdir -p "$1" && cd "$1"
}

# Extract any archive
extract() {
    if [ -f $1 ]; then
        case $1 in
            *.tar.bz2)   tar xjf $1     ;;
            *.tar.gz)    tar xzf $1     ;;
            *.bz2)       bunzip2 $1     ;;
            *.rar)       unrar e $1     ;;
            *.gz)        gunzip $1      ;;
            *.tar)       tar xf $1      ;;
            *.tbz2)      tar xjf $1     ;;
            *.tgz)       tar xzf $1     ;;
            *.zip)       unzip $1       ;;
            *.Z)         uncompress $1  ;;
            *.7z)        7z x $1        ;;
            *)           echo "$1 cannot be extracted" ;;
        esac
    else
        echo "$1 is not a valid file"
    fi
}

# Yazi shell wrapper (cd on exit)
function yy() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

# ───────────────────────────────────────────────────────────────────
# COMPLETIONS
# ───────────────────────────────────────────────────────────────────
autoload -Uz compinit
compinit

# ───────────────────────────────────────────────────────────────────
# KEY BINDINGS
# ───────────────────────────────────────────────────────────────────
bindkey "^[[A" up-line-or-search
bindkey "^[OA" up-line-or-search
bindkey "^[[B" down-line-or-search
bindkey "^[OB" down-line-or-search
