#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

for file in \
    "$ROOT/bin/portalgun" \
    "$ROOT/installers/portalgun_install.sh" \
    "$ROOT/lib/doctor.sh" \
    "$ROOT/lib/install_p3ta_tricks.sh" \
    "$ROOT/lib/sync_web.sh" \
    "$ROOT/tests/validate_p3ta_tricks_live.sh"
do
    bash -n "$file" || fail "bash syntax: $file"
done
command -v zsh >/dev/null 2>&1 || fail "zsh is required for completion validation"
zsh -n "$ROOT/completion/_portalgun" || fail "zsh syntax: completion/_portalgun"
pass "p3ta-tricks shell syntax"

grep -Fq 'install p3ta-tricks' "$ROOT/bin/portalgun" || fail "CLI help is missing"
grep -Fq 'update_p3ta_tricks' "$ROOT/bin/portalgun" || fail "CLI update is missing"
grep -Fq 'verify_p3ta_tricks_section' "$ROOT/bin/portalgun" || fail "CLI verification is missing"
grep -Fq 'refreshed against the final tool inventory' "$ROOT/bin/portalgun" || fail "bundle replay refresh is missing"
pass "p3ta-tricks CLI integration"

grep -Fq 'PORTALGUN_SKIP_P3TA_TRICKS' "$ROOT/installers/portalgun_install.sh" || fail "skip policy is missing"
grep -Fq 'install_p3ta_tricks' "$ROOT/installers/portalgun_install.sh" || fail "default install is missing"
grep -Fq 'PORTALGUN_NAV_START' "$ROOT/installers/portalgun_install.sh" || fail "web navigation marker is missing"
pass "p3ta-tricks default integration"

grep -Fq 'Environment=OFFLINE_MODE=1' "$ROOT/lib/install_p3ta_tricks.sh" || fail "offline mode is missing"
grep -Fq 'resolved_commit' "$ROOT/lib/install_p3ta_tricks.sh" || fail "provenance is missing"
grep -Fq 'processed_page_count' "$ROOT/lib/install_p3ta_tricks.sh" || fail "page count is missing"
grep -Fq 'ProtectSystem=strict' "$ROOT/lib/install_p3ta_tricks.sh" || fail "service hardening is missing"
pass "p3ta-tricks service integration"

grep -Fq 'portalgun-p3ta-tricks.service' "$ROOT/lib/sync_web.sh" || fail "web synchronization does not refresh p3ta-tricks"
grep -Fq 'p3ta-tricks:' "$ROOT/lib/doctor.sh" || fail "doctor does not report p3ta-tricks"
[ -s "$ROOT/docs/P3TA_TRICKS.md" ] || fail "component documentation is missing"
grep -Fq -- '--offline-check' "$ROOT/tests/validate_p3ta_tricks_live.sh" || fail "offline acceptance gate is missing"
grep -Fq -- '--restart-check' "$ROOT/tests/validate_p3ta_tricks_live.sh" || fail "restart acceptance gate is missing"
pass "p3ta-tricks refresh diagnostics documentation and live acceptance"
