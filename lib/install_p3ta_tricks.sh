#!/usr/bin/env bash
# Portalgun integration for p3ta00/p3ta-tricks-offline.
# Portalgun owns staging, dependencies, service lifecycle, rollback, verification,
# and registry state; the upstream installer is intentionally not executed.

set -euo pipefail

PORTALGUN_P3TA_TRICKS_REPOSITORY="${PORTALGUN_P3TA_TRICKS_REPOSITORY:-https://github.com/p3ta00/p3ta-tricks-offline.git}"
PORTALGUN_P3TA_TRICKS_REF="${PORTALGUN_P3TA_TRICKS_REF:-main}"
PORTALGUN_P3TA_TRICKS_ROOT="${PORTALGUN_P3TA_TRICKS_ROOT:-/opt/portalgun/p3ta-tricks-offline}"
PORTALGUN_P3TA_TRICKS_HOST="${PORTALGUN_P3TA_TRICKS_HOST:-0.0.0.0}"
PORTALGUN_P3TA_TRICKS_PORT="${PORTALGUN_P3TA_TRICKS_PORT:-1339}"
PORTALGUN_P3TA_TRICKS_USER="${PORTALGUN_P3TA_TRICKS_USER:-portalgun-p3ta}"
PORTALGUN_P3TA_TRICKS_SERVICE="${PORTALGUN_P3TA_TRICKS_SERVICE:-portalgun-p3ta-tricks.service}"
PORTALGUN_P3TA_TRICKS_TOOLS_DIR="${PORTALGUN_P3TA_TRICKS_TOOLS_DIR:-/opt/tools}"
PORTALGUN_P3TA_TRICKS_MIN_PAGES="${PORTALGUN_P3TA_TRICKS_MIN_PAGES:-3000}"
PORTALGUN_P3TA_TRICKS_REGISTRY="${PORTALGUN_P3TA_TRICKS_REGISTRY:-/var/lib/portalgun/registry/knowledge/p3ta-tricks-offline.json}"
PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR="${PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR:-/etc/systemd/system}"
PORTALGUN_P3TA_TRICKS_LAUNCHER="${PORTALGUN_P3TA_TRICKS_LAUNCHER:-/usr/local/bin/p3ta-tricks}"
PORTALGUN_P3TA_TRICKS_HEALTH_ATTEMPTS="${PORTALGUN_P3TA_TRICKS_HEALTH_ATTEMPTS:-30}"

_p3ta_info() {
    if declare -F print_status >/dev/null 2>&1; then print_status "$*"; else printf '[*] %s\n' "$*"; fi
}
_p3ta_success() {
    if declare -F print_success >/dev/null 2>&1; then print_success "$*"; else printf '[+] %s\n' "$*"; fi
}
_p3ta_die() {
    if declare -F print_error >/dev/null 2>&1; then print_error "$*"; else printf '[-] %s\n' "$*" >&2; fi
    return 1
}

_p3ta_require_root() {
    [ "$(id -u)" -eq 0 ] || _p3ta_die "p3ta-tricks provisioning must run as root"
}

_p3ta_validate_configuration() {
    if [ "${PORTALGUN_P3TA_TRICKS_ALLOW_UNSAFE_ROOT:-0}" != "1" ]; then
        case "$PORTALGUN_P3TA_TRICKS_ROOT" in
            /opt/portalgun/*) ;;
            *) _p3ta_die "unsafe p3ta-tricks root: $PORTALGUN_P3TA_TRICKS_ROOT"; return 1 ;;
        esac
    elif [[ "$PORTALGUN_P3TA_TRICKS_ROOT" != /* ]]; then
        _p3ta_die "p3ta-tricks root must be absolute"; return 1
    fi

    [[ "$PORTALGUN_P3TA_TRICKS_PORT" =~ ^[0-9]+$ ]] &&
        [ "$PORTALGUN_P3TA_TRICKS_PORT" -ge 1 ] &&
        [ "$PORTALGUN_P3TA_TRICKS_PORT" -le 65535 ] || {
            _p3ta_die "invalid p3ta-tricks port: $PORTALGUN_P3TA_TRICKS_PORT"; return 1;
        }
    [[ "$PORTALGUN_P3TA_TRICKS_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || {
        _p3ta_die "invalid p3ta-tricks bind host"; return 1;
    }
    [[ "$PORTALGUN_P3TA_TRICKS_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
        _p3ta_die "invalid p3ta-tricks service user"; return 1;
    }
    [[ "$PORTALGUN_P3TA_TRICKS_SERVICE" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || {
        _p3ta_die "invalid p3ta-tricks service name"; return 1;
    }
    [ -n "$PORTALGUN_P3TA_TRICKS_REF" ] &&
        [[ "$PORTALGUN_P3TA_TRICKS_REF" != -* ]] &&
        [[ "$PORTALGUN_P3TA_TRICKS_REF" != *$'\n'* ]] || {
            _p3ta_die "invalid p3ta-tricks git ref"; return 1;
        }
    [[ "$PORTALGUN_P3TA_TRICKS_MIN_PAGES" =~ ^[0-9]+$ ]] &&
        [ "$PORTALGUN_P3TA_TRICKS_MIN_PAGES" -ge 1 ] || {
            _p3ta_die "invalid minimum page count"; return 1;
        }
}

_p3ta_install_prerequisites() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        ca-certificates curl git python3 python3-pip python3-venv
}

_p3ta_ensure_service_user() {
    getent group "$PORTALGUN_P3TA_TRICKS_USER" >/dev/null 2>&1 ||
        groupadd --system "$PORTALGUN_P3TA_TRICKS_USER"
    id "$PORTALGUN_P3TA_TRICKS_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$PORTALGUN_P3TA_TRICKS_USER" \
            --home-dir "$PORTALGUN_P3TA_TRICKS_ROOT" --no-create-home \
            --shell /usr/sbin/nologin "$PORTALGUN_P3TA_TRICKS_USER"
}

_p3ta_validate_checkout() {
    local source_root="$1"
    python3 - "$source_root" "$PORTALGUN_P3TA_TRICKS_MIN_PAGES" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
minimum_pages = int(sys.argv[2])
required_files = (
    "README.md", "app.py", "requirements.txt", "static/css/style.css",
    "static/js/app.js", "static/js/fuse.min.js", "static/js/mermaid.min.js",
    "static/js/prism-bundle.min.js",
)
required_dirs = ("content/processed", "content/nav", "sources", "templates")

for relative in required_files:
    if not (root / relative).is_file():
        raise SystemExit(f"missing required upstream file: {relative}")
for relative in required_dirs:
    if not (root / relative).is_dir():
        raise SystemExit(f"missing required upstream directory: {relative}")

for candidate in root.rglob("*"):
    mode = candidate.lstat().st_mode
    if candidate.is_symlink():
        try:
            resolved = candidate.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise SystemExit(f"invalid symbolic link {candidate.relative_to(root)}: {exc}")
        if resolved != root and root not in resolved.parents:
            raise SystemExit(
                f"symbolic link escapes checkout: {candidate.relative_to(root)} -> {os.readlink(candidate)}"
            )
    elif not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
        raise SystemExit(f"unsupported checkout entry: {candidate.relative_to(root)}")

page_count = sum(1 for _ in (root / "content/processed").rglob("*.json"))
if page_count < minimum_pages:
    raise SystemExit(f"processed content is incomplete: {page_count}/{minimum_pages} pages")
print(page_count)
PY
}

_p3ta_stage_release() {
    local stage_root="$1" source_root="$1/source" venv_root="$1/venv"
    mkdir -p "$source_root"

    _p3ta_info "Fetching p3ta-tricks-offline ref $PORTALGUN_P3TA_TRICKS_REF"
    git -C "$source_root" init -q
    git -C "$source_root" remote add origin "$PORTALGUN_P3TA_TRICKS_REPOSITORY"
    git -C "$source_root" -c protocol.version=2 fetch --depth=1 --no-tags \
        origin "$PORTALGUN_P3TA_TRICKS_REF"
    git -C "$source_root" rev-parse --verify 'FETCH_HEAD^{commit}' >/dev/null
    git -C "$source_root" checkout -q --detach FETCH_HEAD

    local page_count
    page_count=$(_p3ta_validate_checkout "$source_root")

    _p3ta_info "Creating isolated p3ta-tricks Python environment"
    python3 -m venv "$venv_root"
    if [ -d "$source_root/vendor" ] &&
        find "$source_root/vendor" -mindepth 1 -print -quit | grep -q .; then
        "$venv_root/bin/python3" -m pip install --disable-pip-version-check \
            --no-input --no-index --find-links "$source_root/vendor" \
            -r "$source_root/requirements.txt"
    else
        "$venv_root/bin/python3" -m pip install --disable-pip-version-check \
            --no-input --upgrade pip
        "$venv_root/bin/python3" -m pip install --disable-pip-version-check \
            --no-input -r "$source_root/requirements.txt"
    fi

    "$venv_root/bin/python3" - <<'PY'
import flask, gunicorn, markdown, pygments, yaml
PY
    "$venv_root/bin/python3" -m pip freeze > "$stage_root/python-packages.txt"
    printf '%s\n' "$page_count" > "$stage_root/page-count"
    git -C "$source_root" rev-parse HEAD > "$stage_root/resolved-commit"
    chown -R root:root "$stage_root"
    chmod -R a+rX,u+w,go-w "$stage_root"
}

_p3ta_unit_path() { printf '%s/%s' "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR" "$PORTALGUN_P3TA_TRICKS_SERVICE"; }

_p3ta_install_service_unit() {
    local unit_path temporary
    unit_path=$(_p3ta_unit_path)
    temporary="${unit_path}.tmp.$$"
    install -d -m 0755 "$PORTALGUN_P3TA_TRICKS_SYSTEMD_DIR"
    cat > "$temporary" <<EOF
[Unit]
Description=Portalgun p3ta-tricks offline knowledge service
After=network.target

[Service]
Type=simple
User=$PORTALGUN_P3TA_TRICKS_USER
Group=$PORTALGUN_P3TA_TRICKS_USER
WorkingDirectory=$PORTALGUN_P3TA_TRICKS_ROOT/source
Environment=OFFLINE_MODE=1
Environment=TOOLS_DIR=$PORTALGUN_P3TA_TRICKS_TOOLS_DIR
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
ExecStart=$PORTALGUN_P3TA_TRICKS_ROOT/venv/bin/gunicorn --bind $PORTALGUN_P3TA_TRICKS_HOST:$PORTALGUN_P3TA_TRICKS_PORT --workers 2 --timeout 60 --access-logfile - --error-logfile - app:app
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$temporary"
    mv -f "$temporary" "$unit_path"
    systemctl daemon-reload
}

_p3ta_install_launcher() {
    local temporary="${PORTALGUN_P3TA_TRICKS_LAUNCHER}.tmp.$$"
    install -d -m 0755 "$(dirname "$PORTALGUN_P3TA_TRICKS_LAUNCHER")"
    cat > "$temporary" <<EOF
#!/usr/bin/env bash
set -euo pipefail
service=$PORTALGUN_P3TA_TRICKS_SERVICE
port=$PORTALGUN_P3TA_TRICKS_PORT
case "\${1:-status}" in
    status) systemctl --no-pager --full status "\$service" ;;
    start|stop|restart) sudo systemctl "\$1" "\$service" ;;
    url) printf 'http://127.0.0.1:%s/\\n' "\$port" ;;
    *) echo "usage: p3ta-tricks [status|start|stop|restart|url]" >&2; exit 64 ;;
esac
EOF
    chmod 0755 "$temporary"
    mv -f "$temporary" "$PORTALGUN_P3TA_TRICKS_LAUNCHER"
}

_p3ta_health_url() {
    local host="$PORTALGUN_P3TA_TRICKS_HOST"
    case "$host" in 0.0.0.0|::|'[::]') host="127.0.0.1" ;; esac
    if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then host="[$host]"; fi
    printf 'http://%s:%s/' "$host" "$PORTALGUN_P3TA_TRICKS_PORT"
}

_p3ta_health_check() {
    local body
    body=$(curl --fail --silent --show-error --max-time 5 "$(_p3ta_health_url)") || return 1
    grep -Eqi 'p3ta[- ]tricks|p3ta_tricks' <<< "$body"
}

_p3ta_wait_for_health() {
    local attempt
    for attempt in $(seq 1 "$PORTALGUN_P3TA_TRICKS_HEALTH_ATTEMPTS"); do
        _p3ta_health_check && return 0
        sleep 1
    done
    _p3ta_die "p3ta-tricks health check failed: $(_p3ta_health_url)"
}

_p3ta_write_registry() {
    local resolved_commit="$1" page_count="$2" installed_at
    installed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    install -d -m 0755 "$(dirname "$PORTALGUN_P3TA_TRICKS_REGISTRY")"
    python3 - "$PORTALGUN_P3TA_TRICKS_REGISTRY" \
        "$PORTALGUN_P3TA_TRICKS_REPOSITORY" "$PORTALGUN_P3TA_TRICKS_REF" \
        "$resolved_commit" "$PORTALGUN_P3TA_TRICKS_ROOT" \
        "$PORTALGUN_P3TA_TRICKS_HOST" "$PORTALGUN_P3TA_TRICKS_PORT" \
        "$PORTALGUN_P3TA_TRICKS_SERVICE" "$PORTALGUN_P3TA_TRICKS_USER" \
        "$PORTALGUN_P3TA_TRICKS_TOOLS_DIR" "$page_count" "$installed_at" \
        "$(_p3ta_health_url)" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
(
 destination, repository, requested_ref, resolved_commit, install_root, host,
 port, service, service_user, tools_dir, page_count, installed_at, health_url,
) = sys.argv[1:]
payload = {
 "name": "p3ta-tricks-offline", "type": "offline-knowledge", "status": "complete",
 "repository": repository, "requested_ref": requested_ref,
 "resolved_commit": resolved_commit, "install_root": install_root,
 "service": service, "service_user": service_user, "host": host,
 "port": int(port), "url": f"http://{host}:{port}/", "health_url": health_url,
 "tools_dir": tools_dir, "offline_mode": True,
 "processed_page_count": int(page_count), "installed_at": installed_at,
}
path = Path(destination)
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
    os.chmod(temporary, 0o644); os.replace(temporary, path)
finally:
    try: os.unlink(temporary)
    except FileNotFoundError: pass
PY
}

install_p3ta_tricks() (
    set -euo pipefail
    _p3ta_require_root
    _p3ta_validate_configuration
    _p3ta_info "Installing p3ta-tricks offline knowledge service"
    _p3ta_install_prerequisites
    _p3ta_ensure_service_user

    local parent_root previous_root stage_root unit_path
    local unit_backup="" launcher_backup=""
    local previous_install=0 tree_activated=0 committed=0
    parent_root=$(dirname "$PORTALGUN_P3TA_TRICKS_ROOT")
    previous_root="${PORTALGUN_P3TA_TRICKS_ROOT}.previous"
    unit_path=$(_p3ta_unit_path)
    install -d -m 0755 "$parent_root"
    stage_root=$(mktemp -d "$parent_root/.p3ta-tricks-stage.XXXXXX")

    cleanup() {
        local rc=$?
        [ -z "$stage_root" ] || rm -rf -- "$stage_root"

        if [ "$committed" -ne 1 ]; then
            systemctl stop "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
            if [ "$tree_activated" -eq 1 ]; then
                rm -rf -- "$PORTALGUN_P3TA_TRICKS_ROOT"
                if [ "$previous_install" -eq 1 ] && [ -d "$previous_root" ]; then
                    mv "$previous_root" "$PORTALGUN_P3TA_TRICKS_ROOT"
                fi
            fi

            if [ -n "$unit_backup" ] && [ -f "$unit_backup" ]; then
                mv -f "$unit_backup" "$unit_path"
            else
                rm -f "$unit_path"
            fi
            if [ -n "$launcher_backup" ] && [ -f "$launcher_backup" ]; then
                mv -f "$launcher_backup" "$PORTALGUN_P3TA_TRICKS_LAUNCHER"
            else
                rm -f "$PORTALGUN_P3TA_TRICKS_LAUNCHER"
            fi

            systemctl daemon-reload >/dev/null 2>&1 || true
            if [ "$previous_install" -eq 1 ]; then
                systemctl enable "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
                systemctl restart "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
            else
                systemctl disable "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
            fi
        else
            rm -rf -- "$previous_root"
            [ -z "$unit_backup" ] || rm -f "$unit_backup"
            [ -z "$launcher_backup" ] || rm -f "$launcher_backup"
        fi
        return "$rc"
    }
    trap cleanup EXIT

    _p3ta_stage_release "$stage_root"
    if [ -f "$unit_path" ]; then
        unit_backup=$(mktemp "$parent_root/.p3ta-tricks-unit.XXXXXX")
        cp -a "$unit_path" "$unit_backup"
    fi
    if [ -f "$PORTALGUN_P3TA_TRICKS_LAUNCHER" ]; then
        launcher_backup=$(mktemp "$parent_root/.p3ta-tricks-launcher.XXXXXX")
        cp -a "$PORTALGUN_P3TA_TRICKS_LAUNCHER" "$launcher_backup"
    fi

    _p3ta_install_service_unit
    _p3ta_install_launcher
    systemctl stop "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
    rm -rf -- "$previous_root"
    if [ -e "$PORTALGUN_P3TA_TRICKS_ROOT" ]; then
        mv "$PORTALGUN_P3TA_TRICKS_ROOT" "$previous_root"
        previous_install=1
    fi
    mv "$stage_root" "$PORTALGUN_P3TA_TRICKS_ROOT"
    stage_root=""; tree_activated=1

    systemctl enable "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null
    systemctl restart "$PORTALGUN_P3TA_TRICKS_SERVICE"
    _p3ta_wait_for_health

    local resolved_commit page_count
    resolved_commit=$(cat "$PORTALGUN_P3TA_TRICKS_ROOT/resolved-commit")
    page_count=$(cat "$PORTALGUN_P3TA_TRICKS_ROOT/page-count")
    _p3ta_write_registry "$resolved_commit" "$page_count"
    committed=1
    _p3ta_success "p3ta-tricks ready on port $PORTALGUN_P3TA_TRICKS_PORT ($page_count pages, commit ${resolved_commit:0:12})"
)

update_p3ta_tricks() { install_p3ta_tricks; }

verify_p3ta_tricks() {
    _p3ta_validate_configuration
    local source_root="$PORTALGUN_P3TA_TRICKS_ROOT/source"
    local venv_root="$PORTALGUN_P3TA_TRICKS_ROOT/venv"
    local page_count current_commit recorded_commit recorded_pages

    [ -d "$source_root" ] || { _p3ta_die "p3ta-tricks source tree is missing"; return 1; }
    [ -x "$venv_root/bin/gunicorn" ] || { _p3ta_die "p3ta-tricks runtime is missing"; return 1; }
    [ -s "$PORTALGUN_P3TA_TRICKS_REGISTRY" ] || { _p3ta_die "p3ta-tricks registry is missing"; return 1; }

    page_count=$(_p3ta_validate_checkout "$source_root")
    current_commit=$(git -C "$source_root" rev-parse HEAD)
    recorded_commit=$(jq -r '.resolved_commit // empty' "$PORTALGUN_P3TA_TRICKS_REGISTRY")
    recorded_pages=$(jq -r '.processed_page_count // 0' "$PORTALGUN_P3TA_TRICKS_REGISTRY")
    [ "$current_commit" = "$recorded_commit" ] || { _p3ta_die "checkout differs from registry"; return 1; }
    [ "$page_count" = "$recorded_pages" ] || { _p3ta_die "page count differs from registry"; return 1; }

    jq -e --arg root "$PORTALGUN_P3TA_TRICKS_ROOT" \
        --arg service "$PORTALGUN_P3TA_TRICKS_SERVICE" \
        --arg user "$PORTALGUN_P3TA_TRICKS_USER" \
        --argjson port "$PORTALGUN_P3TA_TRICKS_PORT" \
        '.status == "complete" and .offline_mode == true and
         .install_root == $root and .service == $service and
         .service_user == $user and .port == $port' \
        "$PORTALGUN_P3TA_TRICKS_REGISTRY" >/dev/null || {
            _p3ta_die "p3ta-tricks registry is inconsistent"; return 1;
        }
    systemctl is-enabled --quiet "$PORTALGUN_P3TA_TRICKS_SERVICE" || { _p3ta_die "service is not enabled"; return 1; }
    systemctl is-active --quiet "$PORTALGUN_P3TA_TRICKS_SERVICE" || { _p3ta_die "service is not active"; return 1; }
    _p3ta_health_check || { _p3ta_die "HTTP health check failed"; return 1; }

    printf 'status=complete\nservice=%s\nurl=%s\nresolved_commit=%s\nprocessed_page_count=%s\n' \
        "$PORTALGUN_P3TA_TRICKS_SERVICE" "$(_p3ta_health_url)" "$current_commit" "$page_count"
}

verify_p3ta_tricks_section() {
    local PASS_MARK="\033[0;32m✓\033[0m" FAIL_MARK="\033[0;31m✗\033[0m"
    local failures=0 source_root="$PORTALGUN_P3TA_TRICKS_ROOT/source" page_count="?" commit="unknown"
    _p3ta_row() { printf '  %b %-32s %s\n' "$1" "$2" "$3"; }

    echo "── Offline knowledge ─────────────────────"
    if [ -d "$source_root" ] && page_count=$(_p3ta_validate_checkout "$source_root" 2>/dev/null); then
        commit=$(git -C "$source_root" rev-parse --short=12 HEAD 2>/dev/null || true)
        _p3ta_row "$PASS_MARK" "p3ta-tricks content" "$page_count pages; commit $commit"
    else
        _p3ta_row "$FAIL_MARK" "p3ta-tricks content" "missing, unsafe, or incomplete"; failures=$((failures + 1))
    fi
    if [ -x "$PORTALGUN_P3TA_TRICKS_ROOT/venv/bin/gunicorn" ]; then
        _p3ta_row "$PASS_MARK" "p3ta-tricks runtime" "isolated Gunicorn environment"
    else
        _p3ta_row "$FAIL_MARK" "p3ta-tricks runtime" "isolated environment missing"; failures=$((failures + 1))
    fi
    if systemctl is-enabled --quiet "$PORTALGUN_P3TA_TRICKS_SERVICE" 2>/dev/null &&
        systemctl is-active --quiet "$PORTALGUN_P3TA_TRICKS_SERVICE" 2>/dev/null; then
        _p3ta_row "$PASS_MARK" "p3ta-tricks service" "enabled and active on port $PORTALGUN_P3TA_TRICKS_PORT"
    else
        _p3ta_row "$FAIL_MARK" "p3ta-tricks service" "not enabled and active"; failures=$((failures + 1))
    fi
    if _p3ta_health_check 2>/dev/null; then
        _p3ta_row "$PASS_MARK" "p3ta-tricks HTTP" "$(_p3ta_health_url)"
    else
        _p3ta_row "$FAIL_MARK" "p3ta-tricks HTTP" "health check failed"; failures=$((failures + 1))
    fi
    if [ -s "$PORTALGUN_P3TA_TRICKS_REGISTRY" ] &&
        jq -e '.status == "complete" and .offline_mode == true' "$PORTALGUN_P3TA_TRICKS_REGISTRY" >/dev/null 2>&1; then
        _p3ta_row "$PASS_MARK" "p3ta-tricks registry" "complete and offline"
    else
        _p3ta_row "$FAIL_MARK" "p3ta-tricks registry" "missing or inconsistent"; failures=$((failures + 1))
    fi
    [ "$failures" -eq 0 ] || return 2
}
