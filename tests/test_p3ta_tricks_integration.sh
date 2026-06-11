#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

for file in "$ROOT/bin/portalgun" "$ROOT/completion/_portalgun" "$ROOT/installers/portalgun_install.sh" "$ROOT/lib/install_p3ta_tricks.sh"; do
    bash -n "$file" || fail "bash syntax: $file"
done
pass "p3ta-tricks shell syntax"

grep -Fq 'install p3ta-tricks' "$ROOT/bin/portalgun" || fail "CLI help is missing"
grep -Fq 'update_p3ta_tricks' "$ROOT/bin/portalgun" || fail "CLI update is missing"
grep -Fq 'verify_p3ta_tricks_section' "$ROOT/bin/portalgun" || fail "CLI verification is missing"
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
