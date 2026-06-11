#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

for file in \
    "$ROOT/install.sh" \
    "$ROOT/installers/install_tools.sh" \
    "$ROOT/lib/install_apt.sh" \
    "$ROOT/lib/install_github.sh" \
    "$ROOT/lib/sync_scripts.sh"
do
    bash -n "$file" || fail "bash syntax: $file"
done
pass "repository-hygiene shell syntax"

if grep -Fq '$SCRIPT_DIR/../data/failed_packages.txt' \
    "$ROOT/installers/install_tools.sh"
then
    fail "package failure report still targets the source checkout"
fi

grep -Fq 'FAILED_FILE="$PORTALGUN_LOG_DIR/failed_packages.txt"' \
    "$ROOT/installers/install_tools.sh" ||
    fail "package failure report is not stored under runtime logs"

grep -Fq 'PORTALGUN_SYNC_LEGACY_SCRIPTS=0' "$ROOT/install.sh" ||
    fail "full installer does not disable legacy source synchronization"

grep -Fq '${PORTALGUN_SYNC_LEGACY_SCRIPTS:-0}' \
    "$ROOT/lib/install_apt.sh" ||
    fail "APT source synchronization is not opt-in"

grep -Fq '${PORTALGUN_SYNC_LEGACY_SCRIPTS:-0}' \
    "$ROOT/lib/install_github.sh" ||
    fail "GitHub source synchronization is not opt-in"

mkdir -p \
    "$TMP/repo/installers" \
    "$TMP/repo/data" \
    "$TMP/registry/github" \
    "$TMP/lib"

cp "$ROOT/installers/install_github_tools.sh" \
    "$TMP/repo/installers/install_github_tools.sh"
cp "$ROOT/data/installable_packages.txt" \
    "$TMP/repo/data/installable_packages.txt"
cp "$ROOT/lib/sync_github.py" "$TMP/lib/sync_github.py"

cp "$TMP/repo/installers/install_github_tools.sh" \
    "$TMP/install_github_tools.before"
cp "$TMP/repo/data/installable_packages.txt" \
    "$TMP/installable_packages.before"

cat >"$TMP/registry/github/acme_example.json" <<'JSON'
{
  "name": "example-tool",
  "repo": "acme/example-tool",
  "os": "linux",
  "category": "misc",
  "language": "none",
  "build_cmd": "",
  "target": "/opt/tools/linux/misc"
}
JSON

print_warning() { :; }
print_success() { :; }

export PORTALGUN_REPO_DIR="$TMP/repo"
export PORTALGUN_REGISTRY="$TMP/registry"
export PORTALGUN_LIB="$TMP/lib"
export PORTALGUN_SYNC_LEGACY_SCRIPTS=0

# shellcheck source=lib/sync_scripts.sh
source "$ROOT/lib/sync_scripts.sh"

sync_apt_to_script portalgun-test-package
sync_github_to_script acme_example

cmp -s \
    "$TMP/installable_packages.before" \
    "$TMP/repo/data/installable_packages.txt" ||
    fail "default APT synchronization modified source data"

cmp -s \
    "$TMP/install_github_tools.before" \
    "$TMP/repo/installers/install_github_tools.sh" ||
    fail "default GitHub synchronization modified source installer"

pass "runtime synchronization leaves repository files unchanged"

export PORTALGUN_SYNC_LEGACY_SCRIPTS=1

sync_apt_to_script portalgun-test-package
sync_github_to_script acme_example

grep -qx 'portalgun-test-package' \
    "$TMP/repo/data/installable_packages.txt" ||
    fail "explicit APT maintenance synchronization failed"

grep -Fq '"example-tool|acme/example-tool|' \
    "$TMP/repo/installers/install_github_tools.sh" ||
    fail "explicit GitHub maintenance synchronization failed"

pass "legacy repository synchronization remains explicitly available"
