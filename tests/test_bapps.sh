#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

bash -n "$ROOT/lib/install_burp.sh" ||
    fail "install_burp.sh syntax"

python3 - "$ROOT/lib/cache_official_bapps.py" <<'PY'
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(), filename=str(path))
PY

export BURP_DIR="$TMP_DIR/burp"
export BURP_BAPPS_DIR="$TMP_DIR/bapps"
export BURP_BAPP_CACHE_HELPER="$TMP_DIR/fake-cache.py"

cat > "$BURP_BAPP_CACHE_HELPER" <<'PY'
#!/usr/bin/env python3
import os
raise SystemExit(int(os.environ.get("FAKE_BAPP_RC", "0")))
PY

chmod 755 "$BURP_BAPP_CACHE_HELPER"

# shellcheck source=/dev/null
source "$ROOT/lib/install_burp.sh"

set +e
FAKE_BAPP_RC=2 \
PORTALGUN_BAPP_CACHE_MODE=official \
PORTALGUN_REQUIRE_BAPP_CACHE=0 \
cache_official_bapps >/dev/null 2>&1
optional_rc=$?
set -e

[ "$optional_rc" -eq 2 ] ||
    fail "optional partial BApp cache must return 2"

set +e
FAKE_BAPP_RC=2 \
PORTALGUN_BAPP_CACHE_MODE=official \
PORTALGUN_REQUIRE_BAPP_CACHE=1 \
cache_official_bapps >/dev/null 2>&1
strict_rc=$?
set -e

[ "$strict_rc" -eq 1 ] ||
    fail "strict partial BApp cache must return 1"

set +e
PORTALGUN_BAPP_CACHE_MODE=invalid \
cache_official_bapps >/dev/null 2>&1
invalid_rc=$?
set -e

[ "$invalid_rc" -eq 64 ] ||
    fail "invalid BApp cache mode must return 64"

python3 - "$ROOT/lib/cache_official_bapps.py" "$TMP_DIR" <<'PY'
import importlib.util
import pathlib
import sys
import zipfile

module_path = pathlib.Path(sys.argv[1])
tmp_dir = pathlib.Path(sys.argv[2])

spec = importlib.util.spec_from_file_location(
    "cache_official_bapps",
    module_path,
)

module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

uuid = "9cff8c55432a45808432e26dbb2b41d8"
package = tmp_dir / "synthetic.bapp"

manifest = "\n".join(
    [
        f"Uuid: {uuid}",
        "Name: Synthetic Test Extension",
        "EntryPoint: build/test.jar",
        "SerialVersion: 1",
        "",
    ]
)

with zipfile.ZipFile(package, "w") as archive:
    archive.writestr("BappManifest.bmf", manifest)
    archive.writestr("BappSignature.sig", b"test-signature")
    archive.writestr("build/test.jar", b"test-jar")

parsed = module.validate_bapp(package, uuid)

assert parsed["Name"] == "Synthetic Test Extension"
assert parsed["EntryPoint"] == "build/test.jar"

prefixed_package = tmp_dir / "synthetic-prefixed-entrypoint.bapp"

prefixed_manifest = "\n".join(
    [
        f"Uuid: {uuid}",
        "Name: Synthetic Prefixed Extension",
        "EntryPoint: ./build/prefixed.jar",
        "SerialVersion: 2",
        "",
    ]
)

with zipfile.ZipFile(prefixed_package, "w") as archive:
    archive.writestr("./BappManifest.bmf", prefixed_manifest)
    archive.writestr("./BappSignature.sig", b"test-signature")
    archive.writestr("build/prefixed.jar", b"test-jar")

prefixed = module.validate_bapp(prefixed_package, uuid)

assert prefixed["Name"] == "Synthetic Prefixed Extension"
assert prefixed["EntryPoint"] == "./build/prefixed.jar"

version_dir = tmp_dir / "serial-pruning"
version_dir.mkdir()

current_package = version_dir / "current-serial.bapp"
old_package = version_dir / "old-serial.bapp"

current_package.write_bytes(b"current")
old_package.write_bytes(b"obsolete")

module.prune_sibling_versions(current_package)

assert current_package.exists()
assert not old_package.exists()
PY

if grep -Fq 'git clone' "$ROOT/lib/install_burp.sh"; then
    fail "legacy BApp source cloning remains"
fi

if grep -Fq 'release-fetch-fail' "$ROOT/lib/install_burp.sh"; then
    fail "legacy GitHub release probing remains"
fi

grep -Fq 'cache_official_bapps.py' "$ROOT/lib/install_burp.sh" ||
    fail "official BApp cache helper is not integrated"

grep -Fq 'Official BApp cache' "$ROOT/lib/verify.sh" ||
    fail "verifier does not audit official BApp packages"

grep -Fq 'official packages cached' "$ROOT/lib/verify.sh" ||
    fail "verifier does not report official package counts"

if grep -Fq 'signed packages cached' "$ROOT/lib/verify.sh"; then
    fail "verifier incorrectly claims cryptographic signature validation"
fi

grep -Fq 'PORTALGUN_REQUIRE_BAPP_CACHE' "$ROOT/lib/verify.sh" ||
    fail "verifier does not support strict BApp cache policy"

pass "official BApp cache policies and package validation"
