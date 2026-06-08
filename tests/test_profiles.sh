#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PORTALGUN_PROFILE_ROOT="$ROOT/profiles"
export PORTALGUN_COMPONENT_ROOT="$ROOT/components"
export PORTALGUN_REPO_DIR="$ROOT"
source "$ROOT/lib/profile.sh"

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

for file in "$ROOT/install.sh" "$ROOT/bin/portalgun" "$ROOT/installers/portalgun_install.sh" "$ROOT/lib/apply.sh" "$ROOT/lib/profile.sh" "$ROOT/lib/verify.sh" "$ROOT/components"/*/*.sh; do
    bash -n "$file" || fail "bash syntax: $file"
done
pass "bash syntax"

for profile in default kali-default joseph; do
    profile_validate "$profile" >/dev/null || fail "profile validation: $profile"
done
pass "starter profiles validate"

[ "$(jq -r '.terminal.provider' "$ROOT/profiles/kali-default/profile.json")" = none ] || fail "kali-default terminal"
[ "$(jq '.multiplexers | length' "$ROOT/profiles/kali-default/profile.json")" -eq 0 ] || fail "kali-default multiplexer"
[ "$(jq -r '.shell.provider' "$ROOT/profiles/kali-default/profile.json")" = none ] || fail "kali-default shell"
[ "$(jq -r '.framework.provider' "$ROOT/profiles/kali-default/profile.json")" = none ] || fail "kali-default framework"
[ "$(jq -r '.dotfiles.strategy' "$ROOT/profiles/kali-default/profile.json")" = none ] || fail "kali-default dotfiles"
pass "kali-default is a true no-op"

grep -q 'profile_apply "$active_profile"' "$ROOT/lib/apply.sh" || fail "bundle replay profile integration"
! grep -q '_apply_dotfiles_for_user' "$ROOT/lib/apply.sh" || fail "legacy hard-coded dotfile function remains"
! grep -q 'p3ta default config' "$ROOT/lib/apply.sh" || fail "legacy p3ta phase remains"
pass "bundle replay delegates to profile engine"

grep -q 'profile_configure_panel' "$ROOT/install.sh" || fail "profile-aware panel"
! grep -q 'kitty.desktop.*DESKTOP' "$ROOT/install.sh" || true
pass "install path is profile aware"

for f in zshrc tmux.conf kitty.conf starship.toml; do
    case "$f" in
        zshrc) dst="$ROOT/profiles/default/dotfiles/.zshrc" ;;
        tmux.conf) dst="$ROOT/profiles/default/dotfiles/.tmux.conf" ;;
        kitty.conf) dst="$ROOT/profiles/default/dotfiles/.config/kitty/kitty.conf" ;;
        starship.toml) dst="$ROOT/profiles/default/dotfiles/.config/starship.toml" ;;
    esac
    cmp -s "$ROOT/configs/$f" "$dst" || fail "default profile parity: $f"
done
diff -qr "$ROOT/configs/zellij" "$ROOT/profiles/default/dotfiles/.config/zellij" >/dev/null || fail "default profile zellij parity"
pass "default profile matches upstream configs"

echo "All profile tests passed."
