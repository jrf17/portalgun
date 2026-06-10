#!/usr/bin/env python3
"""Build and validate Portalgun's signed Sliver Armory cache."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

SCHEMA_VERSION = 1
USER_AGENT = "portalgun-sliver-armory-cache/1.0"
OFFICIAL_REPOSITORY = "https://github.com/sliverarmory/armory"
OFFICIAL_PUBLIC_KEY = (
    "RWSBpxpRWDrD7Fe+VvRE3c2VEDC2NK80rlNCj+BX0gz44Xw07r6KQD9L"
)
DEFAULT_CACHE_ROOT = Path("/opt/portalgun/sliver/armory-cache")
DEFAULT_WORKERS = 4
MAX_WORKERS = 8
REQUEST_RETRIES = 4
REQUEST_TIMEOUT = 90
BUFFER_SIZE = 1024 * 1024

PACKAGE_TYPES = {
    "extension": {
        "catalog_key": "extensions",
        "manifest": "extension.json",
        "wrong_manifest": "alias.json",
        "stage_dir": "extensions",
    },
    "alias": {
        "catalog_key": "aliases",
        "manifest": "alias.json",
        "wrong_manifest": "extension.json",
        "stage_dir": "aliases",
    },
}


class CacheError(RuntimeError):
    """A deterministic cache or validation error."""


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        while chunk := handle.read(BUFFER_SIZE):
            digest.update(chunk)

    return digest.hexdigest()


def package_tree_inventory(package_root: Path) -> dict[str, dict[str, Any]]:
    if not package_root.is_dir() or package_root.is_symlink():
        raise CacheError(f"package tree is invalid: {package_root}")

    inventory: dict[str, dict[str, Any]] = {}

    for candidate in sorted(package_root.rglob("*")):
        relative = candidate.relative_to(package_root).as_posix()

        if candidate.is_symlink():
            raise CacheError(
                f"package tree contains a symbolic link: {relative}"
            )

        if candidate.is_dir():
            continue

        if not candidate.is_file():
            raise CacheError(
                f"package tree contains an unsupported entry: {relative}"
            )

        inventory[relative] = {
            "size_bytes": candidate.stat().st_size,
            "sha256": sha256_file(candidate),
        }

    if not inventory:
        raise CacheError("package tree contains no regular files")

    return inventory


def atomic_replace_tree(source: Path, destination: Path) -> None:
    if not source.is_dir() or source.is_symlink():
        raise CacheError(f"replacement source is invalid: {source}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    staged_temporary = destination.with_name(f".{destination.name}.new")
    staged_backup = destination.with_name(f".{destination.name}.old")

    for candidate in (staged_temporary, staged_backup):
        if candidate.exists() or candidate.is_symlink():
            if candidate.is_dir() and not candidate.is_symlink():
                shutil.rmtree(candidate)
            else:
                candidate.unlink()

    shutil.copytree(source, staged_temporary)

    if destination.exists() or destination.is_symlink():
        os.replace(destination, staged_backup)

    try:
        os.replace(staged_temporary, destination)
    except Exception:
        if staged_backup.exists() or staged_backup.is_symlink():
            os.replace(staged_backup, destination)
        raise
    else:
        if staged_backup.exists() or staged_backup.is_symlink():
            if staged_backup.is_dir() and not staged_backup.is_symlink():
                shutil.rmtree(staged_backup)
            else:
                staged_backup.unlink()


def atomic_json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")

    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    os.replace(temporary, path)


def open_url(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    method: str = "GET",
    follow_redirects: bool = True,
    timeout: int = REQUEST_TIMEOUT,
):
    request_headers = {
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
    }

    if headers:
        request_headers.update(headers)

    request = urllib.request.Request(
        url,
        headers=request_headers,
        method=method,
    )

    opener = (
        urllib.request.build_opener()
        if follow_redirects
        else urllib.request.build_opener(NoRedirectHandler())
    )

    last_error: Exception | None = None

    for attempt in range(1, REQUEST_RETRIES + 1):
        try:
            return opener.open(request, timeout=timeout)

        except urllib.error.HTTPError as exc:
            if (
                not follow_redirects
                and exc.code in {301, 302, 303, 307, 308}
            ):
                return exc

            last_error = exc

            if (
                exc.code in {408, 429, 500, 502, 503, 504}
                and attempt < REQUEST_RETRIES
            ):
                time.sleep(attempt * 2)
                continue

            raise

        except (
            urllib.error.URLError,
            TimeoutError,
            ConnectionError,
        ) as exc:
            last_error = exc

            if attempt < REQUEST_RETRIES:
                time.sleep(attempt * 2)
                continue

            raise

    assert last_error is not None
    raise last_error


def normalize_staged_tree_permissions(cache_root: Path) -> None:
    """Make shared staged Armory trees readable and traversable."""
    for stage_directory in ("extensions", "aliases"):
        stage_root = cache_root / stage_directory

        if not stage_root.exists():
            continue

        if stage_root.is_symlink() or not stage_root.is_dir():
            raise CacheError(
                f"staged Armory root is invalid: {stage_root}"
            )

        candidates = [stage_root, *sorted(stage_root.rglob("*"))]

        for candidate in candidates:
            relative = candidate.relative_to(cache_root).as_posix()

            if candidate.is_symlink():
                raise CacheError(
                    "staged Armory tree contains a symbolic link: "
                    f"{relative}"
                )

            if candidate.is_dir():
                candidate.chmod(0o755)
            elif candidate.is_file():
                candidate.chmod(0o644)
            else:
                raise CacheError(
                    "staged Armory tree contains an unsupported entry: "
                    f"{relative}"
                )


def validate_staged_tree_permissions(cache_root: Path) -> None:
    """Require shared staged Armory content to be operator-readable."""
    for stage_directory in ("extensions", "aliases"):
        stage_root = cache_root / stage_directory

        if not stage_root.exists():
            continue

        if stage_root.is_symlink() or not stage_root.is_dir():
            raise CacheError(
                f"staged Armory root is invalid: {stage_root}"
            )

        candidates = [stage_root, *sorted(stage_root.rglob("*"))]

        for candidate in candidates:
            relative = candidate.relative_to(cache_root).as_posix()

            if candidate.is_symlink():
                raise CacheError(
                    "staged Armory tree contains a symbolic link: "
                    f"{relative}"
                )

            mode = candidate.stat().st_mode & 0o777

            if candidate.is_dir():
                if mode & 0o005 != 0o005:
                    raise CacheError(
                        "staged Armory directory is not "
                        f"target-user traversable: {relative}"
                    )
            elif candidate.is_file():
                if mode & 0o004 != 0o004:
                    raise CacheError(
                        "staged Armory file is not "
                        f"target-user readable: {relative}"
                    )
            else:
                raise CacheError(
                    "staged Armory tree contains an unsupported entry: "
                    f"{relative}"
                )


def download_resumable(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    part_path = destination.with_name(f"{destination.name}.part")
    last_error: Exception | None = None

    for attempt in range(1, REQUEST_RETRIES + 1):
        offset = part_path.stat().st_size if part_path.exists() else 0
        headers = {"Accept": "application/octet-stream"}

        if offset:
            headers["Range"] = f"bytes={offset}-"

        try:
            with open_url(
                url,
                headers=headers,
                timeout=180,
            ) as response:
                append = (
                    offset > 0
                    and getattr(response, "status", 200) == 206
                )

                mode = "ab" if append else "wb"

                with part_path.open(mode) as output:
                    while chunk := response.read(BUFFER_SIZE):
                        output.write(chunk)

            os.replace(part_path, destination)
            return

        except urllib.error.HTTPError as exc:
            last_error = exc

            if exc.code == 416:
                part_path.unlink(missing_ok=True)

        except Exception as exc:
            last_error = exc

        if attempt < REQUEST_RETRIES:
            time.sleep(attempt * 2)
            continue

        assert last_error is not None
        raise last_error


def minisign_verify(
    message: Path,
    signature: Path,
    public_key: str,
) -> None:
    if not shutil.which("minisign"):
        raise CacheError("minisign is required to verify Armory signatures")

    result = subprocess.run(
        [
            "minisign",
            "-Vm",
            str(message),
            "-x",
            str(signature),
            "-P",
            public_key,
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if result.returncode:
        output = result.stdout.strip().splitlines()
        detail = output[-1] if output else "unknown minisign error"
        raise CacheError(f"signature verification failed: {detail}")


def latest_release_tag(repository_url: str) -> str:
    latest_url = repository_url.rstrip("/") + "/releases/latest"

    with open_url(
        latest_url,
        method="HEAD",
        follow_redirects=False,
    ) as response:
        location = response.headers.get("Location", "")

    if not location:
        raise CacheError(
            f"latest release redirect has no Location header: {repository_url}"
        )

    parsed = urllib.parse.urlparse(location)
    segments = [segment for segment in parsed.path.split("/") if segment]

    try:
        tag_index = segments.index("tag")
        tag = segments[tag_index + 1]
    except (ValueError, IndexError) as exc:
        raise CacheError(
            f"unable to derive release tag from redirect: {location}"
        ) from exc

    if not tag or "/" in tag or tag in {".", ".."}:
        raise CacheError(f"unsafe release tag: {tag!r}")

    return tag



def release_tag_candidates(latest_tag: str) -> list[str]:
    candidates = [latest_tag]
    prefix = "v" if latest_tag.startswith("v") else ""
    numeric = latest_tag[1:] if prefix else latest_tag
    components = numeric.split(".")

    if (
        len(components) != 3
        or not all(component.isdigit() for component in components)
    ):
        return candidates

    major, minor, patch = (int(component) for component in components)

    # Package assets are occasionally omitted from the latest repository
    # release even though the signed Armory index still advertises them.
    # Probe older patch releases without using the GitHub API.
    minimum_patch = max(-1, patch - 64)

    for candidate_patch in range(patch - 1, minimum_patch, -1):
        candidates.append(
            f"{prefix}{major}.{minor}.{candidate_patch}"
        )

    return candidates


def fetch_official_index(cache_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    release_tag = latest_release_tag(OFFICIAL_REPOSITORY)
    release_base = (
        f"{OFFICIAL_REPOSITORY}/releases/download/{release_tag}"
    )

    source_dir = cache_root / "source"
    source_dir.mkdir(parents=True, exist_ok=True)

    index_path = source_dir / "armory.json"
    signature_path = source_dir / "armory.minisig"

    download_resumable(f"{release_base}/armory.json", index_path)
    download_resumable(f"{release_base}/armory.minisig", signature_path)

    minisign_verify(
        index_path,
        signature_path,
        OFFICIAL_PUBLIC_KEY,
    )

    try:
        catalog = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CacheError(f"official Armory index is invalid: {exc}") from exc

    source = {
        "repository": OFFICIAL_REPOSITORY,
        "release_tag": release_tag,
        "index_url": f"{release_base}/armory.json",
        "signature_url": f"{release_base}/armory.minisig",
        "index_path": str(index_path.relative_to(cache_root)),
        "signature_path": str(signature_path.relative_to(cache_root)),
        "index_sha256": sha256_file(index_path),
        "public_key": OFFICIAL_PUBLIC_KEY,
    }

    return catalog, source


def load_preseed_index(
    cache_root: Path,
    preseed: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    index_path = preseed / "armory.json"
    signature_path = preseed / "armory.minisig"

    if not index_path.is_file() or not signature_path.is_file():
        raise CacheError(
            "preseed must contain armory.json and armory.minisig"
        )

    minisign_verify(
        index_path,
        signature_path,
        OFFICIAL_PUBLIC_KEY,
    )

    try:
        catalog = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CacheError(f"preseed Armory index is invalid: {exc}") from exc

    source_dir = cache_root / "source"
    source_dir.mkdir(parents=True, exist_ok=True)

    cached_index = source_dir / "armory.json"
    cached_signature = source_dir / "armory.minisig"

    shutil.copy2(index_path, cached_index)
    shutil.copy2(signature_path, cached_signature)

    source = {
        "repository": OFFICIAL_REPOSITORY,
        "release_tag": "preseed",
        "index_url": str(index_path),
        "signature_url": str(signature_path),
        "index_path": str(cached_index.relative_to(cache_root)),
        "signature_path": str(cached_signature.relative_to(cache_root)),
        "index_sha256": sha256_file(cached_index),
        "public_key": OFFICIAL_PUBLIC_KEY,
    }

    return catalog, source


def normalize_catalog(
    catalog: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if not isinstance(catalog, dict):
        raise CacheError("Armory index must be a JSON object")

    packages: list[dict[str, Any]] = []
    duplicates: list[dict[str, Any]] = []
    record_counts: dict[str, int] = {}
    unique_counts: dict[str, int] = {}

    for package_type, settings in PACKAGE_TYPES.items():
        catalog_key = settings["catalog_key"]
        records = catalog.get(catalog_key)

        if not isinstance(records, list):
            raise CacheError(f"Armory index field {catalog_key!r} is invalid")

        record_counts[package_type] = len(records)
        by_command: dict[str, dict[str, Any]] = {}

        for index, raw_record in enumerate(records):
            if not isinstance(raw_record, dict):
                raise CacheError(
                    f"{catalog_key}[{index}] must be a JSON object"
                )

            required = (
                "name",
                "command_name",
                "repo_url",
                "public_key",
            )
            missing = [
                field
                for field in required
                if not isinstance(raw_record.get(field), str)
                or not raw_record[field]
            ]

            if missing:
                raise CacheError(
                    f"{catalog_key}[{index}] missing fields: "
                    + ", ".join(missing)
                )

            command = raw_record["command_name"]
            repository = raw_record["repo_url"].rstrip("/")

            parsed_repository = urllib.parse.urlparse(repository)
            if (
                parsed_repository.scheme != "https"
                or parsed_repository.netloc.lower() != "github.com"
            ):
                raise CacheError(
                    f"unsupported package repository: {repository}"
                )

            record = {
                "type": package_type,
                "name": raw_record["name"],
                "command_name": command,
                "repo_url": repository,
                "public_key": raw_record["public_key"],
            }

            previous = by_command.get(command)

            if previous is None:
                by_command[command] = record
                continue

            comparable = ("repo_url", "public_key")

            if any(previous[key] != record[key] for key in comparable):
                raise CacheError(
                    f"conflicting duplicate command in catalog: {command}"
                )

            duplicates.append(
                {
                    "type": package_type,
                    "command_name": command,
                    "repo_url": repository,
                }
            )

        unique_counts[package_type] = len(by_command)
        packages.extend(by_command.values())

    packages.sort(
        key=lambda record: (
            record["type"],
            record["command_name"].lower(),
        )
    )

    summary = {
        "catalog_extension_records": record_counts["extension"],
        "catalog_alias_records": record_counts["alias"],
        "expected_extension_count": unique_counts["extension"],
        "expected_alias_count": unique_counts["alias"],
        "duplicate_records": duplicates,
    }

    return packages, summary


def safe_archive_members(
    archive: tarfile.TarFile,
) -> list[tuple[tarfile.TarInfo, PurePosixPath]]:
    results: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
    normalized_names: set[str] = set()

    for member in archive.getmembers():
        raw_name = member.name.replace("\\", "/")

        while raw_name.startswith("./"):
            raw_name = raw_name[2:]

        if raw_name in {"", "."}:
            continue

        relative = PurePosixPath(raw_name)

        if relative.is_absolute() or ".." in relative.parts:
            raise CacheError(f"unsafe archive member: {member.name!r}")

        if (
            member.issym()
            or member.islnk()
            or member.isdev()
            or member.isfifo()
        ):
            raise CacheError(
                f"unsupported archive member: {member.name!r}"
            )

        normalized = relative.as_posix()

        if normalized in normalized_names:
            raise CacheError(
                f"ambiguous normalized archive path: {normalized!r}"
            )

        normalized_names.add(normalized)
        results.append((member, relative))

    return results


def manifest_command_records(
    manifest: dict[str, Any],
    *,
    package_type: str,
) -> list[dict[str, Any]]:
    if package_type == "extension" and "commands" in manifest:
        commands = manifest.get("commands")

        if not isinstance(commands, list) or not commands:
            raise CacheError(
                "extension manifest commands must be a non-empty array"
            )

        return commands

    return [manifest]


def validate_manifest(
    manifest: Any,
    *,
    package_type: str,
    expected_command: str,
    package_root: Path,
) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise CacheError("package manifest must be a JSON object")

    command_records = manifest_command_records(
        manifest,
        package_type=package_type,
    )
    command_names: set[str] = set()
    references: set[str] = set()

    for command_index, command_record in enumerate(command_records):
        if not isinstance(command_record, dict):
            raise CacheError(
                f"manifest command record {command_index} must be an object"
            )

        command_name = command_record.get("command_name")

        if not isinstance(command_name, str) or not command_name:
            raise CacheError(
                f"manifest command record {command_index} "
                "has an invalid command_name"
            )

        if command_name in command_names:
            raise CacheError(
                f"duplicate command_name in package manifest: {command_name}"
            )

        command_names.add(command_name)
        files = command_record.get("files")

        if not isinstance(files, list) or not files:
            raise CacheError(
                f"manifest command {command_name!r} files must be "
                "a non-empty array"
            )

        for file_index, record in enumerate(files):
            if not isinstance(record, dict):
                raise CacheError(
                    f"manifest command {command_name!r} "
                    f"files[{file_index}] must be an object"
                )

            reference = record.get("path")

            if not isinstance(reference, str) or not reference:
                raise CacheError(
                    f"manifest command {command_name!r} "
                    f"files[{file_index}].path is missing or invalid"
                )

            normalized = PurePosixPath(reference.replace("\\", "/"))

            if (
                normalized.is_absolute()
                or ".." in normalized.parts
                or normalized.as_posix() in {"", "."}
            ):
                raise CacheError(
                    f"unsafe manifest file reference: {reference!r}"
                )

            references.add(normalized.as_posix())

    if expected_command not in command_names:
        raise CacheError(
            f"manifest command selection {sorted(command_names)!r} "
            f"does not match expected command {expected_command!r}"
        )

    missing = [
        reference
        for reference in sorted(references)
        if not package_root.joinpath(
            *PurePosixPath(reference).parts
        ).is_file()
    ]

    if missing:
        raise CacheError(
            "manifest references missing files: " + ", ".join(missing)
        )

    if package_type == "alias":
        for field in ("is_assembly", "is_reflective"):
            if field in manifest and not isinstance(manifest[field], bool):
                raise CacheError(
                    f"alias manifest field {field} must be boolean"
                )

    return manifest

def inspect_package_tree(
    package_root: Path,
    *,
    package_type: str,
    expected_command: str,
) -> dict[str, Any]:
    settings = PACKAGE_TYPES[package_type]
    manifest_path = package_root / settings["manifest"]
    wrong_manifest_path = package_root / settings["wrong_manifest"]

    if wrong_manifest_path.exists():
        raise CacheError(
            f"wrong package type: found {settings['wrong_manifest']}"
        )

    if not manifest_path.is_file():
        raise CacheError(f"missing {settings['manifest']}")

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CacheError(f"invalid {settings['manifest']}: {exc}") from exc

    return validate_manifest(
        manifest,
        package_type=package_type,
        expected_command=expected_command,
        package_root=package_root,
    )


def extract_and_validate_archive(
    archive_path: Path,
    *,
    package_type: str,
    expected_command: str,
    destination: Path | None = None,
) -> dict[str, Any]:
    settings = PACKAGE_TYPES[package_type]

    with tempfile.TemporaryDirectory(
        prefix=f"portalgun-sliver-{expected_command}-"
    ) as temporary_name:
        temporary_root = Path(temporary_name)

        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                members = safe_archive_members(archive)

                for member, relative in members:
                    output = temporary_root.joinpath(*relative.parts)

                    if member.isdir():
                        output.mkdir(parents=True, exist_ok=True)
                        continue

                    if not member.isfile():
                        continue

                    output.parent.mkdir(parents=True, exist_ok=True)
                    source = archive.extractfile(member)

                    if source is None:
                        raise CacheError(
                            f"unable to extract archive member: {member.name}"
                        )

                    with source, output.open("wb") as target:
                        shutil.copyfileobj(source, target)

        except (tarfile.TarError, OSError) as exc:
            raise CacheError(f"invalid tar.gz archive: {exc}") from exc

        manifest_matches = list(
            temporary_root.rglob(settings["manifest"])
        )
        wrong_matches = list(
            temporary_root.rglob(settings["wrong_manifest"])
        )

        if wrong_matches:
            raise CacheError(
                f"wrong package type: found {settings['wrong_manifest']}"
            )

        if len(manifest_matches) != 1:
            raise CacheError(
                f"expected exactly one {settings['manifest']}, "
                f"found {len(manifest_matches)}"
            )

        package_root = manifest_matches[0].parent

        try:
            manifest = json.loads(
                manifest_matches[0].read_text(encoding="utf-8")
            )
        except (
            OSError,
            UnicodeDecodeError,
            json.JSONDecodeError,
        ) as exc:
            raise CacheError(
                f"invalid {settings['manifest']}: {exc}"
            ) from exc

        manifest = validate_manifest(
            manifest,
            package_type=package_type,
            expected_command=expected_command,
            package_root=package_root,
        )

        if destination is not None:
            atomic_replace_tree(package_root, destination)

        return manifest


def find_preseed_artifact(
    preseed: Path,
    command_name: str,
    suffix: str,
) -> Path:
    filename = f"{command_name}.{suffix}"
    matches = sorted(
        path
        for path in preseed.rglob(filename)
        if path.is_file()
    )

    if not matches:
        raise CacheError(f"preseed artifact is missing: {filename}")

    if len(matches) > 1:
        raise CacheError(
            f"preseed artifact is ambiguous: {filename} "
            f"({len(matches)} matches)"
        )

    return matches[0]


def prune_old_releases(package_root: Path, keep: Path) -> None:
    if not package_root.is_dir():
        return

    for candidate in package_root.iterdir():
        if candidate == keep:
            continue

        if candidate.is_dir() and not candidate.is_symlink():
            shutil.rmtree(candidate)
        else:
            candidate.unlink(missing_ok=True)


def prepare_package_release(
    record: dict[str, Any],
    *,
    cache_root: Path,
    selected_release_tag: str,
    latest_release_tag_value: str,
    preseed: Path | None,
) -> dict[str, Any]:
    package_type = record["type"]
    command_name = record["command_name"]
    repository = record["repo_url"]
    public_key = record["public_key"]
    stage_directory = PACKAGE_TYPES[package_type]["stage_dir"]

    package_root = (
        cache_root
        / "packages"
        / stage_directory
        / command_name
    )
    release_root = package_root / selected_release_tag
    archive_path = release_root / f"{command_name}.tar.gz"
    signature_path = release_root / f"{command_name}.minisig"
    staged_path = cache_root / stage_directory / command_name

    if preseed is None:
        release_base = (
            f"{repository}/releases/download/{selected_release_tag}"
        )
        archive_url = f"{release_base}/{command_name}.tar.gz"
        signature_url = f"{release_base}/{command_name}.minisig"
    else:
        archive_source = find_preseed_artifact(
            preseed,
            command_name,
            "tar.gz",
        )
        signature_source = find_preseed_artifact(
            preseed,
            command_name,
            "minisig",
        )
        archive_url = str(archive_source)
        signature_url = str(signature_source)

    downloaded = False
    cached_artifacts_valid = False

    if archive_path.is_file() and signature_path.is_file():
        try:
            minisign_verify(
                archive_path,
                signature_path,
                public_key,
            )
        except Exception:
            if release_root.exists():
                shutil.rmtree(release_root)
        else:
            # A correctly signed but semantically invalid package must not be
            # downloaded repeatedly. Preserve it for diagnostics and let the
            # caller try an older signed release.
            archive_manifest = extract_and_validate_archive(
                archive_path,
                package_type=package_type,
                expected_command=command_name,
            )
            cached_artifacts_valid = True

    if not cached_artifacts_valid:
        release_root.mkdir(parents=True, exist_ok=True)

        if preseed is None:
            download_resumable(archive_url, archive_path)
            download_resumable(signature_url, signature_path)
        else:
            shutil.copy2(Path(archive_url), archive_path)
            shutil.copy2(Path(signature_url), signature_path)

        downloaded = True

        minisign_verify(
            archive_path,
            signature_path,
            public_key,
        )

        archive_manifest = extract_and_validate_archive(
            archive_path,
            package_type=package_type,
            expected_command=command_name,
        )

    with tempfile.TemporaryDirectory(
        prefix=f"portalgun-sliver-verified-{command_name}-"
    ) as verified_name:
        verified_tree = Path(verified_name) / command_name

        verified_manifest = extract_and_validate_archive(
            archive_path,
            package_type=package_type,
            expected_command=command_name,
            destination=verified_tree,
        )

        if verified_manifest != archive_manifest:
            raise CacheError(
                f"archive manifest changed during validation: {command_name}"
            )

        content_files = package_tree_inventory(verified_tree)
        staged_valid = False

        if staged_path.is_dir() and not staged_path.is_symlink():
            try:
                staged_manifest = inspect_package_tree(
                    staged_path,
                    package_type=package_type,
                    expected_command=command_name,
                )
                staged_inventory = package_tree_inventory(staged_path)
                staged_valid = (
                    staged_manifest == archive_manifest
                    and staged_inventory == content_files
                )
            except CacheError:
                staged_valid = False

        if not staged_valid:
            atomic_replace_tree(verified_tree, staged_path)

    prune_old_releases(package_root, release_root)

    release_fallback = (
        preseed is None
        and selected_release_tag != latest_release_tag_value
    )

    return {
        **record,
        "status": "cached",
        "release_tag": selected_release_tag,
        "latest_release_tag": latest_release_tag_value,
        "release_fallback": release_fallback,
        "release_resolution": (
            "preseed"
            if preseed is not None
            else "fallback"
            if release_fallback
            else "latest"
        ),
        "archive_url": archive_url,
        "signature_url": signature_url,
        "archive": str(archive_path.relative_to(cache_root)),
        "signature": str(signature_path.relative_to(cache_root)),
        "staged_path": str(staged_path.relative_to(cache_root)),
        "archive_sha256": sha256_file(archive_path),
        "archive_size_bytes": archive_path.stat().st_size,
        "signature_sha256": sha256_file(signature_path),
        "signature_size_bytes": signature_path.stat().st_size,
        "content_file_count": len(content_files),
        "content_files": content_files,
        "version": archive_manifest.get("version"),
        "downloaded": downloaded,
    }


def prepare_package(
    record: dict[str, Any],
    *,
    cache_root: Path,
    release_tag: str,
    preseed: Path | None,
) -> dict[str, Any]:
    command_name = record["command_name"]

    candidates = (
        ["preseed"]
        if preseed is not None
        else release_tag_candidates(release_tag)
    )
    errors: list[str] = []

    for candidate in candidates:
        try:
            return prepare_package_release(
                record,
                cache_root=cache_root,
                selected_release_tag=candidate,
                latest_release_tag_value=release_tag,
                preseed=preseed,
            )
        except Exception as exc:
            errors.append(f"{candidate}: {exc}")

    raise CacheError(
        f"no valid signed release found for {command_name!r}: "
        + " | ".join(errors)
    )

def validate_cache(
    cache_root: Path,
    *,
    verify_signatures: bool = False,
) -> dict[str, Any]:
    manifest_path = cache_root / "manifest.json"

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CacheError(f"cache manifest is missing or invalid: {exc}") from exc

    if not isinstance(manifest, dict):
        raise CacheError("cache manifest must be a JSON object")

    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise CacheError("unsupported cache manifest schema")

    if manifest.get("status") != "complete":
        raise CacheError("cache manifest is not complete")

    validate_staged_tree_permissions(cache_root)

    packages = manifest.get("packages")

    if not isinstance(packages, list):
        raise CacheError("cache manifest packages field is invalid")

    expected_extensions = manifest.get("expected_extension_count")
    expected_aliases = manifest.get("expected_alias_count")

    if not isinstance(expected_extensions, int) or expected_extensions < 0:
        raise CacheError("invalid expected extension count")

    if not isinstance(expected_aliases, int) or expected_aliases < 0:
        raise CacheError("invalid expected alias count")

    actual_extensions = 0
    actual_aliases = 0
    commands: set[tuple[str, str]] = set()
    total_bytes = 0

    for index, record in enumerate(packages):
        if not isinstance(record, dict):
            raise CacheError(f"package record {index} is invalid")

        package_type = record.get("type")
        command_name = record.get("command_name")

        if package_type not in PACKAGE_TYPES:
            raise CacheError(f"package record {index} has invalid type")

        if not isinstance(command_name, str) or not command_name:
            raise CacheError(f"package record {index} has invalid command")

        identity = (package_type, command_name)

        if identity in commands:
            raise CacheError(
                f"duplicate package record: {package_type}/{command_name}"
            )

        commands.add(identity)

        archive_path = cache_root / str(record.get("archive", ""))
        signature_path = cache_root / str(record.get("signature", ""))
        staged_path = cache_root / str(record.get("staged_path", ""))

        if not archive_path.is_file():
            raise CacheError(f"missing package archive: {command_name}")

        if not signature_path.is_file():
            raise CacheError(f"missing package signature: {command_name}")

        if sha256_file(archive_path) != record.get("archive_sha256"):
            raise CacheError(f"archive digest mismatch: {command_name}")

        if sha256_file(signature_path) != record.get("signature_sha256"):
            raise CacheError(f"signature digest mismatch: {command_name}")

        if verify_signatures:
            minisign_verify(
                archive_path,
                signature_path,
                str(record.get("public_key", "")),
            )

        expected_content_files = record.get("content_files")

        if not isinstance(expected_content_files, dict):
            raise CacheError(
                f"package record has invalid content inventory: {command_name}"
            )

        if record.get("content_file_count") != len(expected_content_files):
            raise CacheError(
                f"package content count mismatch: {command_name}"
            )

        with tempfile.TemporaryDirectory(
            prefix=f"portalgun-sliver-validate-{command_name}-"
        ) as verified_name:
            verified_tree = Path(verified_name) / command_name

            archive_manifest = extract_and_validate_archive(
                archive_path,
                package_type=package_type,
                expected_command=command_name,
                destination=verified_tree,
            )
            archive_inventory = package_tree_inventory(verified_tree)

        if archive_inventory != expected_content_files:
            raise CacheError(
                f"archive content inventory mismatch: {command_name}"
            )

        staged_manifest = inspect_package_tree(
            staged_path,
            package_type=package_type,
            expected_command=command_name,
        )
        staged_inventory = package_tree_inventory(staged_path)

        if staged_manifest != archive_manifest:
            raise CacheError(
                f"staged manifest differs from archive: {command_name}"
            )

        if staged_inventory != expected_content_files:
            raise CacheError(
                f"staged content inventory mismatch: {command_name}"
            )

        total_bytes += archive_path.stat().st_size
        total_bytes += signature_path.stat().st_size

        if package_type == "extension":
            actual_extensions += 1
        else:
            actual_aliases += 1

    if actual_extensions != expected_extensions:
        raise CacheError(
            f"extension count mismatch: "
            f"{actual_extensions}/{expected_extensions}"
        )

    if actual_aliases != expected_aliases:
        raise CacheError(
            f"alias count mismatch: {actual_aliases}/{expected_aliases}"
        )

    if manifest.get("cached_extension_count") != actual_extensions:
        raise CacheError("manifest cached extension count mismatch")

    if manifest.get("cached_alias_count") != actual_aliases:
        raise CacheError("manifest cached alias count mismatch")

    if manifest.get("failures"):
        raise CacheError("cache manifest contains failures")

    return {
        "status": "complete",
        "schema_version": SCHEMA_VERSION,
        "manifest": str(manifest_path),
        "expected_extension_count": expected_extensions,
        "expected_alias_count": expected_aliases,
        "cached_extension_count": actual_extensions,
        "cached_alias_count": actual_aliases,
        "valid_extension_manifests": actual_extensions,
        "valid_alias_manifests": actual_aliases,
        "package_count": len(packages),
        "total_bytes": total_bytes,
        "mode": manifest.get("mode"),
        "source_release_tag": (
            manifest.get("source", {}).get("release_tag")
            if isinstance(manifest.get("source"), dict)
            else None
        ),
    }


def synchronize_cache(
    cache_root: Path,
    *,
    workers: int,
    preseed: Path | None,
) -> dict[str, Any]:
    cache_root.mkdir(parents=True, exist_ok=True)

    if preseed is None:
        catalog, source = fetch_official_index(cache_root)
        mode = "official"
    else:
        catalog, source = load_preseed_index(
            cache_root,
            preseed,
        )
        mode = "preseed"

    packages, catalog_summary = normalize_catalog(catalog)

    repository_tags: dict[str, str] = {}

    if preseed is None:
        repositories = sorted(
            {record["repo_url"] for record in packages}
        )

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(workers, len(repositories) or 1)
        ) as executor:
            future_map = {
                executor.submit(latest_release_tag, repository): repository
                for repository in repositories
            }

            for future in concurrent.futures.as_completed(future_map):
                repository = future_map[future]
                repository_tags[repository] = future.result()

    failures: list[dict[str, Any]] = []
    completed: list[dict[str, Any]] = []

    def process(record: dict[str, Any]) -> dict[str, Any]:
        release_tag = (
            repository_tags[record["repo_url"]]
            if preseed is None
            else "preseed"
        )

        return prepare_package(
            record,
            cache_root=cache_root,
            release_tag=release_tag,
            preseed=preseed,
        )

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=workers
    ) as executor:
        future_map = {
            executor.submit(process, record): record
            for record in packages
        }

        for future in concurrent.futures.as_completed(future_map):
            record = future_map[future]

            try:
                completed.append(future.result())
            except Exception as exc:
                failures.append(
                    {
                        "type": record["type"],
                        "command_name": record["command_name"],
                        "repo_url": record["repo_url"],
                        "error": str(exc),
                    }
                )

    completed.sort(
        key=lambda record: (
            record["type"],
            record["command_name"].lower(),
        )
    )
    failures.sort(
        key=lambda record: (
            record["type"],
            record["command_name"].lower(),
        )
    )

    cached_extensions = sum(
        1 for record in completed if record["type"] == "extension"
    )
    cached_aliases = sum(
        1 for record in completed if record["type"] == "alias"
    )
    total_bytes = sum(
        record["archive_size_bytes"] + record["signature_size_bytes"]
        for record in completed
    )

    complete = (
        not failures
        and cached_extensions
        == catalog_summary["expected_extension_count"]
        and cached_aliases
        == catalog_summary["expected_alias_count"]
    )

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "source": source,
        "mode": mode,
        "status": "complete" if complete else "incomplete",
        **catalog_summary,
        "cached_extension_count": cached_extensions,
        "cached_alias_count": cached_aliases,
        "package_count": len(completed),
        "total_bytes": total_bytes,
        "release_fallback_count": sum(
            1
            for record in completed
            if record.get("release_fallback") is True
        ),
        "release_fallbacks": [
            {
                "type": record["type"],
                "command_name": record["command_name"],
                "repo_url": record["repo_url"],
                "latest_release_tag": record["latest_release_tag"],
                "selected_release_tag": record["release_tag"],
            }
            for record in completed
            if record.get("release_fallback") is True
        ],
        "failures": failures,
        "packages": completed,
    }

    normalize_staged_tree_permissions(cache_root)
    validate_staged_tree_permissions(cache_root)

    atomic_json_write(cache_root / "manifest.json", manifest)
    atomic_json_write(cache_root / "failures.json", failures)

    if not complete:
        raise CacheError(
            f"Armory cache incomplete: "
            f"extensions={cached_extensions}/"
            f"{catalog_summary['expected_extension_count']}, "
            f"aliases={cached_aliases}/"
            f"{catalog_summary['expected_alias_count']}, "
            f"failures={len(failures)}"
        )

    return validate_cache(cache_root)


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and validate Portalgun's Sliver Armory cache"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser(
        "sync",
        help="synchronize the complete signed official cache",
    )
    sync_parser.add_argument(
        "--cache-root",
        type=Path,
        default=DEFAULT_CACHE_ROOT,
    )
    sync_parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
    )
    sync_parser.add_argument(
        "--preseed",
        type=Path,
    )
    sync_parser.add_argument(
        "--json",
        action="store_true",
    )

    validate_parser = subparsers.add_parser(
        "validate",
        help="validate an existing cache",
    )
    validate_parser.add_argument(
        "--cache-root",
        type=Path,
        default=DEFAULT_CACHE_ROOT,
    )
    validate_parser.add_argument(
        "--verify-signatures",
        action="store_true",
    )
    validate_parser.add_argument(
        "--json",
        action="store_true",
    )

    inspect_parser = subparsers.add_parser(
        "inspect-archive",
        help="validate one package archive",
    )
    inspect_parser.add_argument("--archive", type=Path, required=True)
    inspect_parser.add_argument(
        "--type",
        choices=sorted(PACKAGE_TYPES),
        required=True,
    )
    inspect_parser.add_argument("--command-name", required=True)
    inspect_parser.add_argument("--json", action="store_true")

    return parser.parse_args(argv)


def print_summary(summary: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(summary, sort_keys=True))
        return

    for key in sorted(summary):
        print(f"{key}={summary[key]}")


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)

    try:
        if args.command == "sync":
            if args.workers < 1 or args.workers > MAX_WORKERS:
                raise CacheError(
                    f"workers must be between 1 and {MAX_WORKERS}"
                )

            preseed = args.preseed.resolve() if args.preseed else None

            if preseed is not None and not preseed.is_dir():
                raise CacheError(f"preseed directory is invalid: {preseed}")

            summary = synchronize_cache(
                args.cache_root.resolve(),
                workers=args.workers,
                preseed=preseed,
            )
            print_summary(summary, as_json=args.json)
            return 0

        if args.command == "validate":
            summary = validate_cache(
                args.cache_root.resolve(),
                verify_signatures=args.verify_signatures,
            )
            print_summary(summary, as_json=args.json)
            return 0

        if args.command == "inspect-archive":
            manifest = extract_and_validate_archive(
                args.archive.resolve(),
                package_type=args.type,
                expected_command=args.command_name,
            )
            summary = {
                "status": "valid",
                "type": args.type,
                "command_name": args.command_name,
                "version": manifest.get("version"),
            }
            print_summary(summary, as_json=args.json)
            return 0

        raise CacheError(f"unsupported command: {args.command}")

    except CacheError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
