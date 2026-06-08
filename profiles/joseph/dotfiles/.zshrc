# Joseph profile starter. Replace this file with the profile owner's maintained .zshrc.
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""
plugins=(
  git
  sudo
  zsh-autosuggestions
  you-should-use
  zsh-bat
  zsh-syntax-highlighting
)
source "$ZSH/oh-my-zsh.sh"

command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

if [[ -o interactive ]] && [[ -z "$ZELLIJ" ]] && [[ "$TERM_PROGRAM" == "ghostty" ]] && command -v zellij >/dev/null 2>&1; then
  exec zellij
fi
