#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/portalgun-test-p3ta-transaction.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

export PORTALGUN_P3TA_TRICKS_ALLOW_UNSAFE_ROOT=1
export PORTALGUN_P3TA_TRICKS_ROOT="$TMP/live"
export PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR="$TMP/systemd"
export PORTALGUN_P3TA_TRICKS_LAUNCHER="$TMP/bin/p3ta-tricks"
export PORTALGUN_P3TA_TRICKS_REGISTRY="$TMP/registry/p3ta-tricks.json"
export PORTALGUN_P3TA_TRICKS_MIN_PAGES=1
export PORTALGUN_P3TA_TRICKS_USER=synthetic-p3ta
export PORTALGUN_P3TA_TRICKS_SERVICE=synthetic-p3ta.service

source "$ROOT/lib/install_p3ta_tricks.sh"

make_stage() {
    local dst="$1"
    mkdir -p "$dst/source"/{content/{processed,nav},sources,templates,static/{css,js}} "$dst/venv/bin"
    printf '# p3ta-tricks\n' > "$dst/source/README.md"
    printf 'print("p3ta-tricks")\n' > "$dst/source/app.py"
    printf 'Flask==3.0.3\n' > "$dst/source/requirements.txt"
    printf 'body{}\n' > "$dst/source/static/css/style.css"
    for file in app fuse.min mermaid.min prism-bundle.min; do
        printf 'p3ta-tricks\n' > "$dst/source/static/js/$file.js"
    done
    printf '{}\n' > "$dst/source/content/processed/page.json"
    printf '#!/bin/sh\nexit 0\n' > "$dst/venv/bin/gunicorn"
    chmod +x "$dst/venv/bin/gunicorn"
    printf 'new-commit\n' > "$dst/resolved-commit"
    printf '1\n' > "$dst/page-count"
    printf 'Flask==3.0.3\n' > "$dst/python-packages.txt"
}

systemctl() { return 0; }
_p3ta_require_root() { return 0; }
_p3ta_install_prerequisites() { return 0; }
_p3ta_ensure_service_user() { return 0; }
_p3ta_stage_release() { make_stage "$1"; }
_p3ta_install_service_unit() {
    mkdir -p "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR"
    printf 'new-unit\n' > "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR/$PORTALGUN_P3TA_TRICKS_SERVICE"
}
_p3ta_install_launcher() {
    mkdir -p "$(dirname "$PORTALGUN_P3TA_TRICKS_LAUNCHER")"
    printf 'new-launcher\n' > "$PORTALGUN_P3TA_TRICKS_LAUNCHER"
}
_p3ta_wait_for_health() { return 0; }

mkdir -p "$PORTALGUN_P3TA_TRICKS_ROOT" "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR" "$(dirname "$PORTALGUN_P3TA_TRICKS_LAUNCHER")"
printf 'old-tree\n' > "$PORTALGUN_P3TA_TRICKS_ROOT/old-marker"
printf 'old-unit\n' > "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR/$PORTALGUN_P3TA_TRICKS_SERVICE"
printf 'old-launcher\n' > "$PORTALGUN_P3TA_TRICKS_LAUNCHER"

install_p3ta_tricks || fail "successful synthetic deployment failed"
[ -f "$PORTALGUN_P3TA_TRICKS_ROOT/source/README.md" ] || fail "new tree was not activated"
[ ! -e "$PORTALGUN_P3TA_TRICKS_ROOT/old-marker" ] || fail "old tree survived successful deployment"
[ "$(cat "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR/$PORTALGUN_P3TA_TRICKS_SERVICE")" = new-unit ] || fail "new unit was not retained"
[ "$(cat "$PORTALGUN_P3TA_TRICKS_LAUNCHER")" = new-launcher ] || fail "new launcher was not retained"
jq -e '.status == "complete" and .resolved_commit == "new-commit"' "$PORTALGUN_P3TA_TRICKS_REGISTRY" >/dev/null || fail "registry was not committed"
[ ! -e "${PORTALGUN_P3TA_TRICKS_ROOT}.previous" ] || fail "rollback directory survived successful deployment"
pass "p3ta-tricks transactional activation"

rm -rf "$PORTALGUN_P3TA_TRICKS_ROOT"
mkdir -p "$PORTALGUN_P3TA_TRICKS_ROOT"
printf 'old-tree\n' > "$PORTALGUN_P3TA_TRICKS_ROOT/old-marker"
printf 'old-unit\n' > "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR/$PORTALGUN_P3TA_TRICKS_SERVICE"
printf 'old-launcher\n' > "$PORTALGUN_P3TA_TRICKS_LAUNCHER"
rm -f "$PORTALGUN_P3TA_TRICKS_REGISTRY"
_p3ta_wait_for_health() { return 1; }

set +e
install_p3ta_tricks >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "failed health check returned success"
[ -f "$PORTALGUN_P3TA_TRICKS_ROOT/old-marker" ] || fail "old tree was not restored"
[ "$(cat "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR/$PORTALGUN_P3TA_TRICKS_SERVICE")" = old-unit ] || fail "old unit was not restored"
[ "$(cat "$PORTALGUN_P3TA_TRICKS_LAUNCHER")" = old-launcher ] || fail "old launcher was not restored"
[ ! -e "$PORTALGUN_P3TA_TRICKS_REGISTRY" ] || fail "failed deployment wrote registry state"
[ ! -e "${PORTALGUN_P3TA_TRICKS_ROOT}.previous" ] || fail "rollback directory survived failed deployment"
pass "p3ta-tricks failed-health rollback"
