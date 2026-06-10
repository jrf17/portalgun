#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/portalgun-test-sliver.XXXXXX)"

cleanup() {
    rc=$?
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT INT TERM

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

export PORTALGUN_SLIVER_DIR="$TMP_DIR/sliver"
export PORTALGUN_SLIVER_SERVER_ROOT="$TMP_DIR/sliver/server"
export PORTALGUN_SLIVER_ARMORY_CACHE="$TMP_DIR/sliver/armory-cache"
export PORTALGUN_SLIVER_REGISTRY_ROOT="$TMP_DIR/registry"
export PORTALGUN_SLIVER_CACHE_HELPER="$ROOT/lib/cache_sliver_armory.py"
export PORTALGUN_SLIVER_TEST_SKIP_CHOWN=1

source "$ROOT/lib/install_sliver.sh"

unset PORTALGUN_SLIVER_ARMORY_MODE
unset PORTALGUN_REQUIRE_SLIVER_ARMORY

resolve_sliver_armory_mode ||
    fail "default Armory mode must resolve"

[ "$SLIVER_ARMORY_MODE_RESOLVED" = "official" ] ||
    fail "default Armory mode must be official"

PORTALGUN_SLIVER_ARMORY_MODE=off
resolve_sliver_armory_mode ||
    fail "explicit off mode must resolve"

[ "$SLIVER_ARMORY_MODE_RESOLVED" = "off" ] ||
    fail "explicit off mode was not retained"

set +e
PORTALGUN_SLIVER_ARMORY_MODE=invalid
resolve_sliver_armory_mode >/dev/null 2>&1
invalid_mode_rc=$?
set -e

[ "$invalid_mode_rc" -ne 0 ] ||
    fail "invalid Armory mode must fail"

set +e
PORTALGUN_SLIVER_ARMORY_MODE=off
PORTALGUN_REQUIRE_SLIVER_ARMORY=1
resolve_sliver_armory_mode >/dev/null 2>&1
strict_off_rc=$?
set -e

[ "$strict_off_rc" -ne 0 ] ||
    fail "legacy strict mode must reject explicit off mode"

PORTALGUN_SLIVER_ARMORY_MODE=official
PORTALGUN_REQUIRE_SLIVER_ARMORY=1
resolve_sliver_armory_mode ||
    fail "legacy strict mode must resolve to official"

[ "$SLIVER_ARMORY_MODE_RESOLVED" = "official" ] ||
    fail "legacy strict mode did not resolve to official"

unset PORTALGUN_REQUIRE_SLIVER_ARMORY
pass "Sliver Armory policy"

ORIGINAL_GETENT_DEFINITION="$(declare -f getent 2>/dev/null || true)"

getent() {
    case "$1:$2" in
        passwd:synthetic)
            printf 'synthetic:x:1234:1234::%s:/bin/bash\n' "$TMP_DIR/nonstandard-home"
            ;;
        group:1234)
            printf 'synthetic:x:1234:\n'
            ;;
        *)
            return 2
            ;;
    esac
}

mkdir -p "$TMP_DIR/nonstandard-home"
PORTALGUN_TARGET_USER=synthetic

resolve_sliver_target ||
    fail "synthetic target user must resolve through getent"

[ "$SLIVER_TARGET_HOME_RESOLVED" = "$TMP_DIR/nonstandard-home" ] ||
    fail "target home was not obtained from getent"

[[ "$SLIVER_CLIENT_ROOT_RESOLVED" == \
    "$TMP_DIR/nonstandard-home/.sliver-client" ]] ||
    fail "target client root is incorrect"

set +e
PORTALGUN_TARGET_USER=missing
resolve_sliver_target >/dev/null 2>&1
invalid_user_rc=$?
set -e

[ "$invalid_user_rc" -ne 0 ] ||
    fail "invalid target user must fail"

unset -f getent

if [ -n "$ORIGINAL_GETENT_DEFINITION" ]; then
    eval "$ORIGINAL_GETENT_DEFINITION"
fi

pass "Sliver target-user resolution"

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
CURRENT_GROUP="$(id -gn)"

SLIVER_TARGET_USER_RESOLVED="$CURRENT_USER"
SLIVER_TARGET_UID_RESOLVED="$CURRENT_UID"
SLIVER_TARGET_GROUP_RESOLVED="$CURRENT_GROUP"
SLIVER_TARGET_HOME_RESOLVED="$TMP_DIR/target-home"
SLIVER_CLIENT_ROOT_RESOLVED="$TMP_DIR/target-home/.sliver-client"
SLIVER_OPERATOR_CONFIG_RESOLVED="$SLIVER_CLIENT_ROOT_RESOLVED/configs/${SLIVER_OPERATOR_NAME}_${SLIVER_OPERATOR_HOST}.cfg"

mkdir -p \
    "$SLIVER_ARMORY_CACHE/extensions/sample-extension" \
    "$SLIVER_ARMORY_CACHE/aliases/sample-alias" \
    "$SLIVER_CLIENT_ROOT_RESOLVED/extensions" \
    "$SLIVER_CLIENT_ROOT_RESOLVED/aliases" \
    "$SLIVER_CLIENT_ROOT_RESOLVED/configs"

stage_sliver_armory_for_target >/dev/null ||
    fail "target Armory staging failed"

[ -L "$SLIVER_CLIENT_ROOT_RESOLVED/extensions" ] ||
    fail "extensions root was not symlinked"

[ -L "$SLIVER_CLIENT_ROOT_RESOLVED/aliases" ] ||
    fail "aliases root was not symlinked"

[[ "$(readlink -f "$SLIVER_CLIENT_ROOT_RESOLVED/extensions")" == \
    "$(readlink -f "$SLIVER_ARMORY_CACHE/extensions")" ]] ||
    fail "extensions symlink target is incorrect"

[[ "$(readlink -f "$SLIVER_CLIENT_ROOT_RESOLVED/aliases")" == \
    "$(readlink -f "$SLIVER_ARMORY_CACHE/aliases")" ]] ||
    fail "aliases symlink target is incorrect"

stage_sliver_armory_for_target >/dev/null ||
    fail "target Armory staging must be idempotent"

rm "$SLIVER_CLIENT_ROOT_RESOLVED/extensions"
mkdir "$SLIVER_CLIENT_ROOT_RESOLVED/extensions"
printf 'custom\n' > "$SLIVER_CLIENT_ROOT_RESOLVED/extensions/custom"

set +e
stage_sliver_armory_for_target >/dev/null 2>&1
nonempty_rc=$?
set -e

[ "$nonempty_rc" -ne 0 ] ||
    fail "non-empty unrelated extension directory must not be replaced"

pass "Sliver target-user Armory staging"

mkdir -p "$SLIVER_SERVER_ROOT/configs" "$SLIVER_SERVER_ROOT/go/bin" "$SLIVER_SERVER_ROOT/zig"

printf 'server\n' > "$SLIVER_SERVER_ROOT/configs/server.yaml"
printf 'database\n' > "$SLIVER_SERVER_ROOT/configs/database.yaml"
printf 'database\n' > "$SLIVER_SERVER_ROOT/sliver.db"
printf 'nouns\n' > "$SLIVER_SERVER_ROOT/nouns.txt"
printf 'adjectives\n' > "$SLIVER_SERVER_ROOT/adjectives.txt"
printf '#!/bin/sh\n' > "$SLIVER_SERVER_ROOT/go/bin/go"
printf '#!/bin/sh\n' > "$SLIVER_SERVER_ROOT/zig/zig"
chmod +x "$SLIVER_SERVER_ROOT/go/bin/go" "$SLIVER_SERVER_ROOT/zig/zig"

sliver_assets_valid ||
    fail "valid synthetic server assets were rejected"

rm "$SLIVER_SERVER_ROOT/nouns.txt"

set +e
sliver_assets_valid
invalid_assets_rc=$?
set -e

[ "$invalid_assets_rc" -ne 0 ] ||
    fail "partial server assets must fail validation"

pass "Sliver server asset validation"

mkdir -p "$(dirname "$SLIVER_OPERATOR_CONFIG_RESOLVED")"

python3 - "$SLIVER_OPERATOR_CONFIG_RESOLVED" << 'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "operator": "portalgun-local",
            "lhost": "127.0.0.1",
            "lport": 31337,
            "ca_certificate": "ca",
            "certificate": "certificate",
            "private_key": "private-key",
            "token": "token",
        }
    ),
    encoding="utf-8",
)
PY

sliver_operator_config_valid "$SLIVER_OPERATOR_CONFIG_RESOLVED" ||
    fail "valid operator configuration was rejected"

python3 - "$SLIVER_OPERATOR_CONFIG_RESOLVED" << 'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["lhost"] = "0.0.0.0"
path.write_text(json.dumps(value), encoding="utf-8")
PY

set +e
sliver_operator_config_valid "$SLIVER_OPERATOR_CONFIG_RESOLVED"
invalid_config_rc=$?
set -e

[ "$invalid_config_rc" -ne 0 ] ||
    fail "non-loopback operator configuration must fail"

pass "Sliver operator configuration validation"

grep -Fq 'server_path=$(command -v sliver-server' "$ROOT/lib/install_sliver.sh" ||
    fail "registry does not resolve the actual server path"

grep -Fq 'client_path=$(command -v sliver-client' "$ROOT/lib/install_sliver.sh" ||
    fail "registry does not resolve the actual client path"

grep -Fq 'HOME="$SLIVER_TARGET_HOME_RESOLVED"' "$ROOT/lib/install_sliver.sh" ||
    fail "target-user commands do not set HOME explicitly"

grep -Fq 'USER="$SLIVER_TARGET_USER_RESOLVED"' "$ROOT/lib/install_sliver.sh" ||
    fail "target-user commands do not set USER explicitly"

grep -Fq 'LOGNAME="$SLIVER_TARGET_USER_RESOLVED"' "$ROOT/lib/install_sliver.sh" ||
    fail "target-user commands do not set LOGNAME explicitly"

if grep -Fq '/root/.sliver-client' "$ROOT/lib/install_sliver.sh"; then
    fail "installer contains a root-only Sliver client path"
fi

pass "Sliver dynamic paths and target environment"
pass "complete required Sliver provisioning policy"


grep -Fq 'python3 "$sliver_cache_helper" validate' "$ROOT/lib/verify.sh" ||
    fail "verifier does not validate the machine-readable Sliver cache"

grep -Fq 'SLIVER_CLIENT_ROOT_DIR="$sliver_client_root"' "$ROOT/lib/verify.sh" ||
    fail "Sliver smoke test does not set the target client root"

grep -Fq 'HOME="$sliver_home"' "$ROOT/lib/verify.sh" ||
    fail "Sliver verifier does not set target HOME"

grep -Fq 'aliases' "$ROOT/lib/verify.sh" ||
    fail "Sliver smoke test does not validate aliases"

if grep -Fq 'grep -cE "✅"' "$ROOT/lib/verify.sh"; then
    fail "Sliver verifier still depends on emoji counting"
fi

grep -Fq 'sliver_rc=${PIPESTATUS[0]}' "$ROOT/install.sh" ||
    fail "Phase 12 does not capture the Sliver pipeline status"

grep -Fq 'PORTALGUN_TARGET_USER="$PORTALGUN_TARGET_USER"' "$ROOT/install.sh" ||
    fail "Phase 12 does not pass the target user through sudo"

grep -Fq 'PORTALGUN_SLIVER_ARMORY_MODE=' "$ROOT/install.sh" ||
    fail "Phase 12 does not pass the Sliver Armory policy through sudo"

grep -Fq 'SLIVER_PHASE_RC="$sliver_rc"' "$ROOT/install.sh" ||
    fail "Phase 12 does not retain required provisioning failure state"

if grep -Fq 'Sliver install non-fatal failure' "$ROOT/install.sh"; then
    fail "Phase 12 still labels Sliver provisioning failure as nonfatal"
fi

pass "Sliver verifier and Phase 12 integration"
