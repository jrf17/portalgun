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

profile_allows_apt_package ghostty joseph ||
    fail "joseph must allow ghostty"

profile_allows_apt_package zellij joseph ||
    fail "joseph must allow zellij"

profile_allows_apt_package zsh joseph ||
    fail "joseph must allow zsh"

! profile_allows_apt_package kitty joseph ||
    fail "joseph must exclude kitty"

! profile_allows_apt_package tmux joseph ||
    fail "joseph must exclude tmux"

profile_allows_apt_package kitty default ||
    fail "default must allow kitty"

profile_allows_apt_package tmux default ||
    fail "default must allow tmux"

profile_allows_apt_package zellij default ||
    fail "default must allow zellij"

! profile_allows_apt_package kitty kali-default ||
    fail "kali-default must exclude kitty"

! profile_allows_apt_package tmux kali-default ||
    fail "kali-default must exclude tmux"

! profile_allows_apt_package zsh kali-default ||
    fail "kali-default must exclude zsh"

grep -q 'profile_allows_apt_package' "$ROOT/lib/apply.sh" ||
    fail "bundle APT phase does not use profile filter"

grep -q 'profile_allows_apt_package' "$ROOT/lib/verify.sh" ||
    fail "verifier does not use profile filter"

grep -q 'source /opt/portalgun/lib/profile.sh' "$ROOT/install.sh" ||
    fail "bundle replay does not load profile engine"

set +e
profile_allows_apt_package     kitty     profile-that-does-not-exist     >/dev/null 2>&1

invalid_profile_rc=$?
set -e

[ "$invalid_profile_rc" -eq 2 ] ||
    fail "invalid profile must return status 2"

grep -Fq     'apt_profile_excluded=$((apt_profile_excluded + 1))'     "$ROOT/lib/apply.sh" ||
    fail "apply APT exclusion counter is not arithmetic expansion"

grep -Fq     'apt_profile_excluded=$((apt_profile_excluded + 1))'     "$ROOT/lib/verify.sh" ||
    fail "verify APT exclusion counter is not arithmetic expansion"

grep -Fq     'local apt_already=$((apt_count - apt_total - apt_profile_excluded))'     "$ROOT/lib/apply.sh" ||
    fail "apply APT summary is not arithmetic expansion"

grep -Fq     'local cargo_user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-$(id -un)}}"'     "$ROOT/lib/apply.sh" ||
    fail "cargo installation is not target-user aware"

grep -Fq     'local cargo_user="${PORTALGUN_TARGET_USER:-${SUDO_USER:-$(id -un)}}"'     "$ROOT/lib/verify.sh" ||
    fail "cargo verification is not target-user aware"

grep -Fq     'sudo -H -u "$cargo_user"'     "$ROOT/lib/apply.sh" ||
    fail "cargo installation does not switch to the target user"

grep -Fq     'sudo -H -u "$cargo_user"'     "$ROOT/lib/verify.sh" ||
    fail "cargo verification does not switch to the target user"

if grep -Fq '/root/.cargo/bin' "$ROOT/lib/verify.sh"; then
    fail "cargo verification still contains root-only paths"
fi

pass "bundle APT packages respect selected profile"

grep -q 'profile_apply "$active_profile"' "$ROOT/lib/apply.sh" || fail "bundle replay profile integration"
! grep -q '_apply_dotfiles_for_user' "$ROOT/lib/apply.sh" || fail "legacy hard-coded dotfile function remains"
! grep -q 'p3ta default config' "$ROOT/lib/apply.sh" || fail "legacy p3ta phase remains"
pass "bundle replay delegates to profile engine"

grep -q 'profile_configure_panel' "$ROOT/install.sh" || fail "profile-aware panel"
! grep -q 'kitty.desktop.*DESKTOP' "$ROOT/install.sh" || true
pass "install path is profile aware"

grep -Fq 'case "${VERIFY_RC:-2}" in' "$ROOT/install.sh" ||
    fail "installer does not classify verification exit statuses"

grep -Fq     'Installation completed successfully; post-install verification reported warnings'     "$ROOT/install.sh" ||
    fail "installer does not accept verification warnings"

grep -Fq     'Installation completed, but post-install verification failed'     "$ROOT/install.sh" ||
    fail "installer does not preserve hard verification failures"

if grep -Fq     'if [ "${VERIFY_RC:-1}" -ne 0 ]; then'     "$ROOT/install.sh"
then
    fail "installer still treats warnings as hard failures"
fi

pass "installer distinguishes verification warnings from failures"

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
