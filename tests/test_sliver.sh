#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT/lib/install_sliver.sh"

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

stage_bundled_armory() {
    return 1
}

set +e
PORTALGUN_REQUIRE_SLIVER_ARMORY=0     preinstall_sliver_armory >/dev/null 2>&1
optional_rc=$?
set -e

[ "$optional_rc" -eq 2 ] ||
    fail "missing optional armory cache must return 2"

set +e
PORTALGUN_REQUIRE_SLIVER_ARMORY=1     preinstall_sliver_armory >/dev/null 2>&1
required_rc=$?
set -e

[ "$required_rc" -eq 1 ] ||
    fail "missing required armory cache must return 1"

grep -Fq     'server_path=$(command -v sliver-server'     "$ROOT/lib/install_sliver.sh" ||
    fail "Sliver registry does not resolve the actual server path"

grep -Fq     'client_path=$(command -v sliver-client'     "$ROOT/lib/install_sliver.sh" ||
    fail "Sliver registry does not resolve the actual client path"

grep -Fq     'no bundled armory cache was supplied'     "$ROOT/lib/verify.sh" ||
    fail "verifier does not support optional armory cache"

grep -Fq     'PORTALGUN_REQUIRE_SLIVER_ARMORY'     "$ROOT/lib/verify.sh" ||
    fail "verifier does not support strict armory mode"

pass "optional and required Sliver armory policies"
