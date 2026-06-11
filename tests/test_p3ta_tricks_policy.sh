#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/portalgun-test-p3ta-policy.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

export PORTALGUN_P3TA_TRICKS_ALLOW_UNSAFE_ROOT=1
export PORTALGUN_P3TA_TRICKS_ROOT="$TMP_DIR/live"
export PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR="$TMP_DIR/systemd"
export PORTALGUN_P3TA_TRICKS_LAUNCHER="$TMP_DIR/bin/p3ta-tricks"
export PORTALGUN_P3TA_TRICKS_REGISTRY="$TMP_DIR/registry/p3ta-tricks.json"
export PORTALGUN_P3TA_TRICKS_MIN_PAGES=2
export PORTALGUN_P3TA_TRICKS_USER=synthetic-p3ta
export PORTALGUN_P3TA_TRICKS_SERVICE=synthetic-p3ta.service
export PORTALGUN_P3TA_TRICKS_PORT=31339
export PORTALGUN_P3TA_TRICKS_HOST=0.0.0.0

source "$ROOT/lib/install_p3ta_tricks.sh"

make_checkout() {
    local destination="$1"
    mkdir -p "$destination"/{content/{processed,nav},sources,templates,static/{css,js}}
    printf '# p3ta-tricks\n' > "$destination/README.md"
    printf 'print("p3ta-tricks")\n' > "$destination/app.py"
    printf 'Flask==3.0.3\n' > "$destination/requirements.txt"
    printf 'body{}\n' > "$destination/static/css/style.css"
    printf 'app\n' > "$destination/static/js/app.js"
    printf 'fuse\n' > "$destination/static/js/fuse.min.js"
    printf 'mermaid\n' > "$destination/static/js/mermaid.min.js"
    printf 'prism\n' > "$destination/static/js/prism-bundle.min.js"
    printf '{}\n' > "$destination/content/processed/one.json"
    printf '{}\n' > "$destination/content/processed/two.json"
}

unset PORTALGUN_P3TA_TRICKS_ALLOW_UNSAFE_ROOT
if _p3ta_validate_configuration >/dev/null 2>&1; then
    fail "unsafe non-/opt root was accepted"
fi
export PORTALGUN_P3TA_TRICKS_ALLOW_UNSAFE_ROOT=1
_p3ta_validate_configuration || fail "synthetic configuration was rejected"
pass "p3ta-tricks configuration policy"

checkout="$TMP_DIR/checkout"
make_checkout "$checkout"
[ "$(_p3ta_validate_checkout "$checkout")" = "2" ] ||
    fail "valid checkout was rejected"

printf 'outside\n' > "$TMP_DIR/outside.txt"
ln -s "$TMP_DIR/outside.txt" "$checkout/escape"
if _p3ta_validate_checkout "$checkout" >/dev/null 2>&1; then
    fail "escaping symbolic link was accepted"
fi
pass "p3ta-tricks checkout policy"

[ "$(_p3ta_health_url)" = "http://127.0.0.1:31339/" ] ||
    fail "wildcard bind did not map to loopback"
pass "p3ta-tricks health URL policy"

systemctl() { return 0; }
_p3ta_install_service_unit
unit="$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR/$PORTALGUN_P3TA_TRICKS_SERVICE"
grep -Fq 'Environment=OFFLINE_MODE=1' "$unit" || fail "offline mode missing"
grep -Fq 'Environment=TOOLS_DIR=/opt/tools' "$unit" || fail "tools path missing"
grep -Fq 'ProtectSystem=strict' "$unit" || fail "filesystem hardening missing"
grep -Fq 'NoNewPrivileges=true' "$unit" || fail "privilege hardening missing"
pass "p3ta-tricks service policy"
