# Kali Linux Terminal Setup

Automated setup script for configuring a fresh Kali Linux image with a modern terminal environment.

## What's Included

### Terminal & Shell
- **Kitty** - GPU-accelerated terminal (Catppuccin Mocha theme)
- **Zsh** with Oh-My-Zsh
- **Starship** - Cross-shell prompt
- **JetBrains Mono Nerd Font**

### Oh-My-Zsh Plugins
- zsh-syntax-highlighting
- zsh-autosuggestions
- fzf
- sudo
- command-not-found
- git

### Modern CLI Tools
| Tool | Replaces | Description |
|------|----------|-------------|
| eza | ls | Modern ls with icons |
| bat | cat | Cat with syntax highlighting |
| fd | find | Fast file finder |
| ripgrep | grep | Fast grep |
| zoxide | cd | Smart directory jumper |
| fzf | - | Fuzzy finder |
| yazi | - | Terminal file manager |
| lazygit | - | Git TUI |
| btop | top | System monitor |
| neovim | vim | Modern vim |
| tldr | man | Simplified man pages |

## Usage

### Option 1: Run locally on Kali
```bash
# Copy the Kali_Config folder to your Kali machine
# Then run:
cd Kali_Config
./setup.sh
```

### Option 2: Run via SSH
```bash
# From your host machine
scp -r Kali_Config kali@<IP>:~/
ssh kali@<IP> 'cd ~/Kali_Config && ./setup.sh'
```

## Key Bindings

| Binding | Action |
|---------|--------|
| `Ctrl+R` | Fuzzy search command history |
| `Ctrl+T` | Fuzzy find files |
| `Alt+C` | Fuzzy cd to directory |
| `Esc Esc` | Prepend sudo to command |

## Aliases

| Alias | Command |
|-------|---------|
| `ls`, `ll`, `la`, `lt` | eza variants |
| `cat`, `catp` | bat variants |
| `lg` | lazygit |
| `y`, `yy` | yazi (yy changes dir on exit) |
| `top` | btop |
| `help` | tldr |

## Files

```
Kali_Config/
├── setup.sh              # Main setup script
├── README.md             # This file
└── configs/
    ├── zshrc             # Zsh configuration
    ├── kitty.conf        # Kitty terminal config
    └── starship.toml     # Starship prompt config
```
