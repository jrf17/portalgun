#!/usr/bin/env bash
set -euo pipefail

SERVICE="${PORTALGUN_P3TA_TRICKS_SERVICE:-portalgun-p3ta-tricks.service}"
ROOT="${PORTALGUN_P3TA_TRICKS_ROOT:-/opt/portalgun/p3ta-tricks-offline}"
REGISTRY="${PORTALGUN_P3TA_TRICKS_REGISTRY:-/var/lib/portalgun/registry/knowledge/p3ta-tricks-offline.json}"
URL="${PORTALGUN_P3TA_TRICKS_HEALTH_URL:-http://127.0.0.1:1339/}"
MIN_PAGES="${PORTALGUN_P3TA_TRICKS_MIN_PAGES:-3000}"
OFFLINE_CHECK=0
RESTART_CHECK=0

usage() {
    cat <<'EOF'
Usage: sudo tests/validate_p3ta_tricks_live.sh [OPTIONS]

Options:
  --offline-check   Assert the host has no default route before local checks.
  --restart-check   Restart the service and verify it becomes healthy again.
  -h, --help        Show this help.

Run --offline-check only after manually disconnecting the test VM from all
external networks. The script never changes network configuration.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --offline-check) OFFLINE_CHECK=1 ;;
        --restart-check) RESTART_CHECK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

pass=0
fail=0

ok() {
    printf '[PASS] %s\n' "$1"
    pass=$((pass + 1))
}

bad() {
    printf '[FAIL] %s\n' "$1" >&2
    fail=$((fail + 1))
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 2
    }
}

for cmd in curl git jq python3 systemctl; do
    require_cmd "$cmd"
done

if [ "$OFFLINE_CHECK" -eq 1 ]; then
    if ip route show default 2>/dev/null | grep -q .; then
        bad "offline gate: a default route is still present"
    else
        ok "offline gate: no default route is present"
    fi
fi

if systemctl is-enabled --quiet "$SERVICE"; then
    ok "$SERVICE is enabled"
else
    bad "$SERVICE is not enabled"
fi

if systemctl is-active --quiet "$SERVICE"; then
    ok "$SERVICE is active"
else
    bad "$SERVICE is not active"
fi

if [ "$RESTART_CHECK" -eq 1 ]; then
    if systemctl restart "$SERVICE"; then
        healthy=0
        for _ in $(seq 1 30); do
            if curl -fsS --max-time 5 "$URL" | grep -Eqi 'p3ta[- ]tricks|p3ta_tricks'; then
                healthy=1
                break
            fi
            sleep 1
        done
        if [ "$healthy" -eq 1 ]; then
            ok "$SERVICE survives restart"
        else
            bad "$SERVICE did not become healthy after restart"
        fi
    else
        bad "$SERVICE restart failed"
    fi
fi

if curl -fsS --max-time 5 "$URL" | grep -Eqi 'p3ta[- ]tricks|p3ta_tricks'; then
    ok "root page responds with p3ta-tricks content"
else
    bad "root page health check failed"
fi

search_index_url="${URL%/}/static/search_index.json"
if curl -fsS --max-time 10 "$search_index_url" |
    python3 -c 'import json,sys; data=json.load(sys.stdin); assert len(data) >= 1000'
then
    ok "search index is locally available and populated"
else
    bad "search index is missing or unexpectedly small"
fi

if [ -s "$REGISTRY" ] && jq -e '.status == "complete" and .offline_mode == true' "$REGISTRY" >/dev/null; then
    ok "registry reports a complete offline deployment"
else
    bad "registry is missing or inconsistent"
fi

source_root="$ROOT/source"
venv_root="$ROOT/venv"

if [ -d "$source_root/.git" ] && [ -x "$venv_root/bin/gunicorn" ]; then
    ok "source checkout and isolated Gunicorn runtime exist"
else
    bad "source checkout or isolated runtime is missing"
fi

current_commit="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)"
recorded_commit="$(jq -r '.resolved_commit // empty' "$REGISTRY" 2>/dev/null || true)"
if [ -n "$current_commit" ] && [ "$current_commit" = "$recorded_commit" ]; then
    ok "registry commit matches the deployed checkout"
else
    bad "registry commit does not match the deployed checkout"
fi

page_count="$(find "$source_root/content/processed" -type f -name '*.json' 2>/dev/null | wc -l)"
recorded_pages="$(jq -r '.processed_page_count // 0' "$REGISTRY" 2>/dev/null || true)"
if [ "$page_count" -ge "$MIN_PAGES" ] && [ "$page_count" = "$recorded_pages" ]; then
    ok "processed content count is complete and matches the registry ($page_count)"
else
    bad "processed content count is incomplete or inconsistent ($page_count/$recorded_pages)"
fi

service_user="$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)"
if [ -n "$service_user" ] && [ "$service_user" != root ]; then
    ok "service runs as dedicated non-root user $service_user"
else
    bad "service does not run as a dedicated non-root user"
fi

if [ "$(systemctl show -p NoNewPrivileges --value "$SERVICE" 2>/dev/null)" = yes ] &&
   [ "$(systemctl show -p ProtectSystem --value "$SERVICE" 2>/dev/null)" = strict ] &&
   [ "$(systemctl show -p ProtectHome --value "$SERVICE" 2>/dev/null)" = yes ]
then
    ok "systemd privilege and filesystem protections are active"
else
    bad "expected systemd hardening is not active"
fi

if [ -n "$service_user" ] && ! sudo -u "$service_user" test -w "$source_root"; then
    ok "application source tree is not writable by the service account"
else
    bad "application source tree is writable by the service account"
fi

if sudo -u "$service_user" test -r /opt/tools 2>/dev/null; then
    ok "Portalgun tool inventory is readable by the service account"
else
    bad "Portalgun tool inventory is not readable by the service account"
fi

printf '\nPassed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
