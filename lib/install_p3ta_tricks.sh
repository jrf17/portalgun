#!/usr/bin/env bash
# Portalgun integration for p3ta00/p3ta-tricks-offline.
#
# This installer intentionally does not execute the upstream install.sh. Portalgun
# owns dependency installation, service lifecycle, filesystem permissions, health
# checks, and registry state so the integration remains deterministic and does not
# mutate unrelated tool installations.

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

_p3ta_info() {
    if declare -F print_status >/dev/null 2>&1; then
        print_status "$*"
    else
        printf '[*] %s\n' "$*"
    fi
}

_p3ta_success() {
    if declare -F print_success >/dev/null 2>&1; then
        print_success "$*"
    else
        printf '[+] %s\n' "$*"
    fi
}

_p3ta_warn() {
    if declare -F print_warning >/dev/null 2>&1; then
        print_warning "$*"
    else
        printf '[!] %s\n' "$*" >&2
    fi
}

_p3ta_die() {
    if declare -F print_error >/dev/null 2>&1; then
        print_error "$*"
    else
        printf '[-] %s\n' "$*" >&2
    fi
    return 1
}

_p3ta_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        _p3ta_die "p3ta-tricks provisioning must run as root"
        return 1
    fi
}

_p3ta_validate_configuration() {
    case "$PORTALGUN_P3TA_TRICKS_ROOT" in
        /opt/portalgun/*) ;;
        *)
            _p3ta_die "unsafe p3ta-tricks root: $PORTALGUN_P3TA_TRICKS_ROOT"
            return 1
            ;;
    esac

    if ! [[ "$PORTALGUN_P3TA_TRICKS_PORT" =~ ^[0-9]+$ ]] ||
        [ "$PORTALGUN_P3TA_TRICKS_PORT" -lt 1 ] ||
        [ "$PORTALGUN_P3TA_TRICKS_PORT" -gt 65535 ]
    then
        _p3ta_die "invalid p3ta-tricks port: $PORTALGUN_P3TA_TRICKS_PORT"
        return 1
    fi

    if ! [[ "$PORTALGUN_P3TA_TRICKS_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        _p3ta_die "invalid p3ta-tricks bind host: $PORTALGUN_P3TA_TRICKS_HOST"
        return 1
    fi

    if ! [[ "$PORTALGUN_P3TA_TRICKS_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        _p3ta_die "invalid p3ta-tricks service user: $PORTALGUN_P3TA_TRICKS_USER"
        return 1
    fi

    if [ -z "$PORTALGUN_P3TA_TRICKS_REF" ] ||
        [[ "$PORTALGUN_P3TA_TRICKS_REF" == -* ]] ||
        [[ "$PORTALGUN_P3TA_TRICKS_REF" == *$'\n'* ]]
    then
        _p3ta_die "invalid p3ta-tricks git ref"
        return 1
    fi
}

_p3ta_install_prerequisites() {
    local -a packages=(
        ca-certificates
        curl
        git
        python3
        python3-pip
        python3-venv
    )

    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${packages[@]}"
}

_p3ta_ensure_service_user() {
    if ! getent group "$PORTALGUN_P3TA_TRICKS_USER" >/dev/null 2>&1; then
        groupadd --system "$PORTALGUN_P3TA_TRICKS_USER"
    fi

    if ! id "$PORTALGUN_P3TA_TRICKS_USER" >/dev/null 2>&1; then
        useradd \
            --system \
            --gid "$PORTALGUN_P3TA_TRICKS_USER" \
            --home-dir "$PORTALGUN_P3TA_TRICKS_ROOT" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            "$PORTALGUN_P3TA_TRICKS_USER"
    fi
}

_p3ta_validate_checkout() {
    local source_root="$1"

    python3 - "$source_root" "$PORTALGUN_P3TA_TRICKS_MIN_PAGES" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
minimum_pages = int(sys.argv[2])

required_files = (
    "README.md",
    "app.py",
    "requirements.txt",
    "static/css/style.css",
    "static/js/app.js",
    "static/js/fuse.min.js",
    "static/js/mermaid.min.js",
    "static/js/prism-bundle.min.js",
)

for relative in required_files:
    candidate = root / relative
    if not candidate.is_file():
        raise SystemExit(f"missing required upstream file: {relative}")

required_directories = (
    "content/processed",
    "content/nav",
    "sources",
    "templates",
)

for relative in required_directories:
    candidate = root / relative
    if not candidate.is_dir():
        raise SystemExit(f"missing required upstream directory: {relative}")

for candidate in root.rglob("*"):
    if not candidate.is_symlink():
        continue

    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise SystemExit(f"invalid symbolic link {candidate.relative_to(root)}: {exc}")

    if resolved != root and root not in resolved.parents:
        raise SystemExit(
            f"symbolic link escapes checkout: {candidate.relative_to(root)} -> {os.readlink(candidate)}"
        )

page_count = sum(1 for _ in (root / "content/processed").rglob("*.json"))
if page_count < minimum_pages:
    raise SystemExit(
        f"processed content is incomplete: {page_count}/{minimum_pages} pages"
    )

print(page_count)
PY
}

_p3ta_stage_release() {
    local stage_root="$1"
    local source_root="$stage_root/source"
    local venv_root="$stage_root/venv"

    mkdir -p "$source_root"

    _p3ta_info "Fetching p3ta-tricks-offline ref $PORTALGUN_P3TA_TRICKS_REF"
    git -C "$source_root" init -q
    git -C "$source_root" remote add origin "$PORTALGUN_P3TA_TRICKS_REPOSITORY"
    git -C "$source_root" \
        -c protocol.version=2 \
        fetch \
        --depth=1 \
        --no-tags \
        origin \
        "$PORTALGUN_P3TA_TRICKS_REF"
    git -C "$source_root" checkout -q --detach FETCH_HEAD

    local page_count
    page_count=$(_p3ta_validate_checkout "$source_root")

    _p3ta_info "Creating isolated p3ta-tricks Python environment"
    python3 -m venv "$venv_root"
    "$venv_root/bin/python3" -m pip install \
        --disable-pip-version-check \
        --no-input \
        --upgrade pip
    "$venv_root/bin/python3" -m pip install \
        --disable-pip-version-check \
        --no-input \
        -r "$source_root/requirements.txt"

    "$venv_root/bin/python3" - <<'PY'
import flask
import gunicorn
import markdown
import pygments
import yaml
PY

    printf '%s\n' "$page_count" > "$stage_root/page-count"
    git -C "$source_root" rev-parse HEAD > "$stage_root/resolved-commit"

    chown -R root:root "$stage_root"
    chmod -R u=rwX,go=rX "$stage_root"
}

_p3ta_install_service_unit() {
    local unit_path="/etc/systemd/system/$PORTALGUN_P3TA_TRICKS_SERVICE"

    cat > "$unit_path" <<EOF
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
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
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

    chmod 0644 "$unit_path"
    systemctl daemon-reload
}

_p3ta_health_url() {
    local host="$PORTALGUN_P3TA_TRICKS_HOST"

    case "$host" in
        0.0.0.0|::|[::]) host="127.0.0.1" ;;
    esac

    if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
        host="[$host]"
    fi

    printf 'http://%s:%s/' "$host" "$PORTALGUN_P3TA_TRICKS_PORT"
}

_p3ta_wait_for_health() {
    local url
    url=$(_p3ta_health_url)

    local attempt
    for attempt in $(seq 1 30); do
        if curl \
            --fail \
            --silent \
            --show-error \
            --max-time 5 \
            "$url" >/dev/null
        then
            return 0
        fi
        sleep 1
    done

    _p3ta_die "p3ta-tricks health check failed: $url"
}

_p3ta_write_registry() {
    local resolved_commit="$1"
    local page_count="$2"
    local installed_at
    installed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    install -d -m 0755 "$(dirname "$PORTALGUN_P3TA_TRICKS_REGISTRY")"

    python3 - \
        "$PORTALGUN_P3TA_TRICKS_REGISTRY" \
        "$PORTALGUN_P3TA_TRICKS_REPOSITORY" \
        "$PORTALGUN_P3TA_TRICKS_REF" \
        "$resolved_commit" \
        "$PORTALGUN_P3TA_TRICKS_ROOT" \
        "$PORTALGUN_P3TA_TRICKS_HOST" \
        "$PORTALGUN_P3TA_TRICKS_PORT" \
        "$PORTALGUN_P3TA_TRICKS_SERVICE" \
        "$PORTALGUN_P3TA_TRICKS_USER" \
        "$PORTALGUN_P3TA_TRICKS_TOOLS_DIR" \
        "$page_count" \
        "$installed_at" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

(
    destination,
    repository,
    requested_ref,
    resolved_commit,
    install_root,
    host,
    port,
    service,
    service_user,
    tools_dir,
    page_count,
    installed_at,
) = sys.argv[1:]

payload = {
    "name": "p3ta-tricks-offline",
    "type": "offline-knowledge",
    "repository": repository,
    "requested_ref": requested_ref,
    "resolved_commit": resolved_commit,
    "install_root": install_root,
    "service": service,
    "service_user": service_user,
    "host": host,
    "port": int(port),
    "url": f"http://{host}:{port}/",
    "tools_dir": tools_dir,
    "offline_mode": True,
    "processed_page_count": int(page_count),
    "installed_at": installed_at,
}

path = Path(destination)
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

install_p3ta_tricks() {
    _p3ta_require_root
    _p3ta_validate_configuration

    _p3ta_info "Installing p3ta-tricks offline knowledge service"
    _p3ta_install_prerequisites
    _p3ta_ensure_service_user

    local parent_root
    parent_root=$(dirname "$PORTALGUN_P3TA_TRICKS_ROOT")
    install -d -m 0755 "$parent_root"

    local stage_root
    stage_root=$(mktemp -d "$parent_root/.p3ta-tricks-stage.XXXXXX")
    local previous_root="${PORTALGUN_P3TA_TRICKS_ROOT}.previous"
    local rollback_required=0

    _p3ta_cleanup_stage() {
        rm -rf -- "$stage_root"
    }
    trap _p3ta_cleanup_stage RETURN

    _p3ta_stage_release "$stage_root"
    _p3ta_install_service_unit

    systemctl stop "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
    rm -rf -- "$previous_root"

    if [ -e "$PORTALGUN_P3TA_TRICKS_ROOT" ]; then
        mv "$PORTALGUN_P3TA_TRICKS_ROOT" "$previous_root"
        rollback_required=1
    fi

    mv "$stage_root" "$PORTALGUN_P3TA_TRICKS_ROOT"
    stage_root="${PORTALGUN_P3TA_TRICKS_ROOT}.stage-consumed"

    systemctl enable "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null

    if ! systemctl restart "$PORTALGUN_P3TA_TRICKS_SERVICE" ||
        ! _p3ta_wait_for_health
    then
        systemctl stop "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
        rm -rf -- "$PORTALGUN_P3TA_TRICKS_ROOT"

        if [ "$rollback_required" -eq 1 ] && [ -d "$previous_root" ]; then
            mv "$previous_root" "$PORTALGUN_P3TA_TRICKS_ROOT"
            systemctl restart "$PORTALGUN_P3TA_TRICKS_SERVICE" >/dev/null 2>&1 || true
        fi

        _p3ta_die "p3ta-tricks deployment failed; previous installation restored"
        return 1
    fi

    local resolved_commit
    local page_count
    resolved_commit=$(cat "$PORTALGUN_P3TA_TRICKS_ROOT/resolved-commit")
    page_count=$(cat "$PORTALGUN_P3TA_TRICKS_ROOT/page-count")

    _p3ta_write_registry "$resolved_commit" "$page_count"
    rm -rf -- "$previous_root"

    _p3ta_success \
        "p3ta-tricks ready at http://$PORTALGUN_P3TA_TRICKS_HOST:$PORTALGUN_P3TA_TRICKS_PORT ($page_count pages, commit ${resolved_commit:0:12})"
}

verify_p3ta_tricks() {
    _p3ta_validate_configuration

    local source_root="$PORTALGUN_P3TA_TRICKS_ROOT/source"
    local venv_root="$PORTALGUN_P3TA_TRICKS_ROOT/venv"

    [ -d "$source_root" ] || {
        _p3ta_die "p3ta-tricks source tree is missing"
        return 1
    }
    [ -x "$venv_root/bin/gunicorn" ] || {
        _p3ta_die "p3ta-tricks gunicorn environment is missing"
        return 1
    }
    [ -s "$PORTALGUN_P3TA_TRICKS_REGISTRY" ] || {
        _p3ta_die "p3ta-tricks registry record is missing"
        return 1
    }

    local page_count
    page_count=$(_p3ta_validate_checkout "$source_root")

    if ! systemctl is-enabled --quiet "$PORTALGUN_P3TA_TRICKS_SERVICE"; then
        _p3ta_die "p3ta-tricks service is not enabled"
        return 1
    fi

    if ! systemctl is-active --quiet "$PORTALGUN_P3TA_TRICKS_SERVICE"; then
        _p3ta_die "p3ta-tricks service is not active"
        return 1
    fi

    _p3ta_wait_for_health

    local current_commit
    local recorded_commit
    current_commit=$(git -C "$source_root" rev-parse HEAD)
    recorded_commit=$(python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["resolved_commit"])' \
        "$PORTALGUN_P3TA_TRICKS_REGISTRY")

    if [ "$current_commit" != "$recorded_commit" ]; then
        _p3ta_die "p3ta-tricks checkout differs from registry state"
        return 1
    fi

    printf 'status=complete\n'
    printf 'service=%s\n' "$PORTALGUN_P3TA_TRICKS_SERVICE"
    printf 'url=%s\n' "$(_p3ta_health_url)"
    printf 'resolved_commit=%s\n' "$current_commit"
    printf 'processed_page_count=%s\n' "$page_count"
}
