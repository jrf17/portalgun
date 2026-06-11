# Portalgun terminal profiles

Portalgun profiles make the terminal environment declarative without changing the security-tool bundle, Burp, Sliver, registry, or web-catalog workflows.

## Use a profile

```bash
# Interactive selection
./install.sh

# Explicit selection
./install.sh --profile default
./install.sh --profile kali-default
./install.sh --profile joseph

# Unattended deployment
./install.sh --profile joseph --non-interactive

# Validate without installing
./install.sh --profile joseph --validate-profile
```

After Portalgun is installed:

```bash
portalgun profile list
portalgun profile show joseph
portalgun profile validate joseph
sudo portalgun --profile joseph profile apply
portalgun profile current
portalgun --profile joseph profile verify
```

## Built-in profiles

| Profile | Terminal | Multiplexers | Shell | Framework | Targets |
|---|---|---|---|---|---|
| `default` | Kitty | Tmux and Zellij | Zsh | Oh My Zsh | current user and root |
| `kali-default` | Kali default | none | Kali default | none | current user |
| `joseph` | Ghostty | Zellij | Zsh | Oh My Zsh | current user |

The `default` profile reproduces the upstream terminal environment. The `joseph` profile includes the requested plugin repositories and a starter `.zshrc`; replace the files under `profiles/joseph/dotfiles/` with the profile owner's maintained copies.

## `none` preserves Kali defaults

`none` is a valid no-op provider. It never removes packages or replaces existing settings.

- Terminal `none`: do not install or select a terminal emulator; do not replace the XFCE terminal launcher.
- No multiplexers: do not install or auto-start Tmux or Zellij.
- Shell `none`: do not change the login shell.
- Framework `none`: do not install Oh My Zsh, Oh My Bash, or Fisher.
- Dotfile strategy `none`: do not copy profile dotfiles.

## Supported providers

- Terminals: `kitty`, `ghostty`, `tilix`, `alacritty`, `none`
- Multiplexers: `tmux`, `zellij`, or both
- Shells: `zsh`, `bash`, `fish`, `none`
- Frameworks: `oh-my-zsh`, `oh-my-bash`, `fisher`, `none`

Compatibility is validated before installation:

- Oh My Zsh requires Zsh.
- Oh My Bash requires Bash.
- Fisher requires Fish.
- Shell `none` requires framework `none`.

## Profile layout

```text
profiles/<name>/
├── profile.json
└── dotfiles/
    ├── .zshrc
    ├── .tmux.conf
    └── .config/
        ├── ghostty/config
        └── zellij/config.kdl
```

The dotfile tree mirrors the target user's home directory. Portalgun uses `rsync`, backs up replaced files under `~/.local/state/portalgun/backups/`, and rejects profile symlinks that escape the profile directory.

## Target users

Profiles declare their targets:

- `current`: `--target-user`, `SUDO_USER`, or the invoking user
- `root`
- `all-interactive-users`
- an explicit username

Personal profiles should normally target only `current`. The upstream-compatible `default` profile targets `current` and `root` because the synchronized bundle replay historically configured both.

## Bundle replay safety

`portalgun install all` and Phase 10b use the same profile engine as Phase 2. Bundle replay no longer copies hard-coded Kitty, Tmux, Zellij, Zsh, or Oh My Zsh files. It resolves the profile in this order:

1. Explicit `--profile` / `PORTALGUN_PROFILE`
2. `/var/lib/portalgun/profile-state.json`
3. `default`

This prevents the later bundle phase from overwriting the profile chosen at the beginning of `install.sh`.

## Create a profile

```bash
./install.sh --create-profile alice
# or
portalgun profile create alice
```

The interactive wizard creates a manifest and an empty home-mirroring dotfile directory. Add the owner's files and validate:

```bash
portalgun profile validate alice
```
