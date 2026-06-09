#!/usr/bin/env python3
"""Cache official PortSwigger BApp Store packages.

The official .bapp package is the authoritative offline artifact. GitHub
repositories are source references only and are never treated as installed
or loadable Burp extensions.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import html
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

BASE_URL = "https://portswigger.net"
STORE_URL = f"{BASE_URL}/bappstore"
DETAIL_PREFIX = f"{STORE_URL}/"
USER_AGENT = "portalgun-official-bapp-cache/1.0"

DEFAULT_WORKERS = 4
REQUEST_RETRIES = 4
REQUEST_TIMEOUT = 60
BUFFER_SIZE = 1024 * 1024


class DetailParser(HTMLParser):
    """Extract official download and repository links independent of attribute order."""

    def __init__(self) -> None:
        super().__init__()
        self.download_url: str | None = None
        self.repo_url: str | None = None

    def handle_starttag(
        self,
        tag: str,
        attrs: list[tuple[str, str | None]],
    ) -> None:
        if tag.lower() != "a":
            return

        values = {
            key.lower(): value
            for key, value in attrs
            if value is not None
        }

        element_id = values.get("id")
        href = values.get("href")

        if not href:
            return

        if element_id == "DownloadedLink":
            self.download_url = urllib.parse.urljoin(BASE_URL, href)
        elif element_id == "RepoLink":
            self.repo_url = urllib.parse.urljoin(BASE_URL, href)


def open_url(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    timeout: int = REQUEST_TIMEOUT,
):
    request_headers = {
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
    }

    if headers:
        request_headers.update(headers)

    last_error: Exception | None = None

    for attempt in range(1, REQUEST_RETRIES + 1):
        request = urllib.request.Request(
            url,
            headers=request_headers,
            method="GET",
        )

        try:
            return urllib.request.urlopen(
                request,
                timeout=timeout,
            )

        except urllib.error.HTTPError as exc:
            last_error = exc

            if exc.code in {429, 500, 502, 503, 504} and attempt < REQUEST_RETRIES:
                time.sleep(attempt * 2)
                continue

            raise

        except (
            urllib.error.URLError,
            TimeoutError,
            ssl.SSLError,
            ConnectionError,
        ) as exc:
            last_error = exc

            if attempt < REQUEST_RETRIES:
                time.sleep(attempt * 2)
                continue

            raise

    assert last_error is not None
    raise last_error


def fetch_text(url: str) -> str:
    with open_url(
        url,
        headers={"Accept": "text/html,application/xhtml+xml"},
    ) as response:
        return response.read().decode(
            "utf-8",
            errors="replace",
        )


def parse_title(source: str) -> str | None:
    result = re.search(
        r"<title>\s*(.*?)\s*</title>",
        source,
        re.IGNORECASE | re.DOTALL,
    )

    if not result:
        return None

    value = html.unescape(
        re.sub(r"<[^>]+>", " ", result.group(1))
    )

    value = re.sub(r"\s+", " ", value).strip()

    suffix = " - PortSwigger"

    if value.endswith(suffix):
        value = value[: -len(suffix)].strip()

    return value or None


def parse_store_ids(source: str) -> list[str]:
    return sorted(
        set(
            re.findall(
                r'href=["\']/bappstore/([0-9a-f]{32})["\']',
                source,
                re.IGNORECASE,
            )
        )
    )


def parse_manifest(data: bytes) -> dict[str, str]:
    values: dict[str, str] = {}

    for raw_line in data.decode(
        "utf-8",
        errors="replace",
    ).splitlines():
        if ":" not in raw_line:
            continue

        key, value = raw_line.split(":", 1)
        values[key.strip()] = value.strip()

    return values


def validate_bapp(
    path: Path,
    expected_uuid: str | None = None,
) -> dict[str, str]:
    if not path.is_file():
        raise ValueError(f"package is missing: {path}")

    if path.stat().st_size < 100:
        raise ValueError(f"package is too small: {path}")

    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())

            required = {
                "BappManifest.bmf",
                "BappSignature.sig",
            }

            missing = sorted(required - names)

            if missing:
                raise ValueError(
                    "missing required package members: "
                    + ", ".join(missing)
                )

            manifest = parse_manifest(
                archive.read("BappManifest.bmf")
            )

            package_uuid = manifest.get("Uuid")

            if (
                expected_uuid
                and package_uuid
                and package_uuid.lower() != expected_uuid.lower()
            ):
                raise ValueError(
                    f"manifest UUID {package_uuid} does not match "
                    f"expected UUID {expected_uuid}"
                )

            entry_point = manifest.get("EntryPoint")

            if entry_point and entry_point not in names:
                raise ValueError(
                    f"manifest entry point is absent: {entry_point}"
                )

            bad_member = archive.testzip()

            if bad_member:
                raise ValueError(
                    f"archive member failed CRC validation: {bad_member}"
                )

            return manifest

    except zipfile.BadZipFile as exc:
        raise ValueError(f"invalid BApp ZIP archive: {path}") from exc


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        while chunk := handle.read(BUFFER_SIZE):
            digest.update(chunk)

    return digest.hexdigest()


def download_resumable(
    url: str,
    part_path: Path,
) -> None:
    part_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    last_error: Exception | None = None

    for attempt in range(1, REQUEST_RETRIES + 1):
        offset = (
            part_path.stat().st_size
            if part_path.exists()
            else 0
        )

        headers = {
            "Accept": "application/octet-stream",
        }

        if offset > 0:
            headers["Range"] = f"bytes={offset}-"

        try:
            with open_url(
                url,
                headers=headers,
                timeout=120,
            ) as response:
                append = (
                    offset > 0
                    and getattr(response, "status", 200) == 206
                )

                mode = "ab" if append else "wb"

                with part_path.open(mode) as output:
                    while chunk := response.read(BUFFER_SIZE):
                        output.write(chunk)

                return

        except urllib.error.HTTPError as exc:
            last_error = exc

            if exc.code == 416:
                part_path.unlink(missing_ok=True)

            if attempt < REQUEST_RETRIES:
                time.sleep(attempt * 2)
                continue

            raise

        except Exception as exc:
            last_error = exc

            if attempt < REQUEST_RETRIES:
                time.sleep(attempt * 2)
                continue

            raise

    assert last_error is not None
    raise last_error


def prune_sibling_versions(destination: Path) -> None:
    """Keep only the validated serial currently referenced by the manifest."""

    for candidate in destination.parent.glob("*.bapp"):
        if candidate != destination:
            candidate.unlink(missing_ok=True)


def cache_package(
    url: str,
    destination: Path,
    expected_uuid: str,
) -> tuple[dict[str, str], bool]:
    """Return validated manifest and whether a new download occurred."""

    if destination.is_file():
        try:
            manifest = validate_bapp(
                destination,
                expected_uuid,
            )

            prune_sibling_versions(destination)

            return manifest, False

        except ValueError:
            destination.unlink(missing_ok=True)

    part_path = Path(f"{destination}.part")

    for package_attempt in range(2):
        download_resumable(
            url,
            part_path,
        )

        try:
            manifest = validate_bapp(
                part_path,
                expected_uuid,
            )

            destination.parent.mkdir(
                parents=True,
                exist_ok=True,
            )

            os.replace(
                part_path,
                destination,
            )

            prune_sibling_versions(destination)

            return manifest, True

        except ValueError:
            part_path.unlink(missing_ok=True)

            if package_attempt == 1:
                raise

    raise RuntimeError(
        f"unable to cache package: {expected_uuid}"
    )


def inspect_detail(
    uuid: str,
    *,
    cache_dir: Path,
    mode: str,
) -> dict[str, Any]:
    detail_url = f"{DETAIL_PREFIX}{uuid}"

    record: dict[str, Any] = {
        "uuid": uuid,
        "detail_url": detail_url,
        "status": "error",
    }

    try:
        source = fetch_text(detail_url)

        parser = DetailParser()
        parser.feed(source)

        record.update(
            {
                "name": parse_title(source),
                "repo_url": parser.repo_url,
                "download_url": parser.download_url,
            }
        )

        if not parser.download_url:
            raise ValueError(
                "official detail page has no DownloadedLink"
            )

        serial_match = re.search(
            rf"/bappstore/bapps/download/"
            rf"{re.escape(uuid)}/(\d+)",
            parser.download_url,
            re.IGNORECASE,
        )

        if not serial_match:
            raise ValueError(
                "unable to identify serial version from download URL"
            )

        serial_version = int(serial_match.group(1))
        record["serial_version"] = serial_version

        if mode == "metadata":
            record["status"] = "metadata"
            return record

        destination = (
            cache_dir
            / "packages"
            / uuid
            / f"{uuid}-{serial_version}.bapp"
        )

        manifest, downloaded = cache_package(
            parser.download_url,
            destination,
            uuid,
        )

        record.update(
            {
                "status": "cached",
                "package": str(
                    destination.relative_to(cache_dir)
                ),
                "size_bytes": destination.stat().st_size,
                "sha256": sha256_file(destination),
                "downloaded": downloaded,
                "manifest": manifest,
                "name": manifest.get("Name")
                or record.get("name"),
                "screen_version": manifest.get(
                    "ScreenVersion"
                ),
                "entry_point": manifest.get("EntryPoint"),
                "extension_type": manifest.get(
                    "ExtensionType"
                ),
                "pro_only": manifest.get("ProOnly"),
                "supported_products": manifest.get(
                    "SupportedProducts"
                ),
            }
        )

        return record

    except Exception as exc:
        record["error"] = str(exc)
        return record


def atomic_json_write(
    path: Path,
    value: Any,
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary = Path(f"{path}.tmp")

    temporary.write_text(
        json.dumps(
            value,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )

    os.replace(
        temporary,
        path,
    )


def write_readme(cache_dir: Path) -> None:
    readme = cache_dir / "README.txt"

    readme.write_text(
        "Portalgun official BApp package cache\n"
        "=====================================\n\n"
        "Packages under packages/ are official .bapp archives "
        "downloaded from the PortSwigger BApp Store.\n\n"
        "They are cached for offline installation. They are not silently "
        "enabled inside Burp Suite. Import a required .bapp through Burp's "
        "Extensions/BApp interface when operating offline.\n\n"
        "manifest.json records package versions, paths, sizes and SHA-256 "
        "digests.\n"
    )


def human_size(size: int) -> str:
    value = float(size)

    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.2f} {unit}"

        value /= 1024

    return str(size)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Cache official PortSwigger BApp Store packages"
        )
    )

    parser.add_argument(
        "--cache-dir",
        required=True,
        type=Path,
    )

    parser.add_argument(
        "--mode",
        choices=("official", "metadata", "off"),
        default="official",
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
    )

    return parser


def main() -> int:
    args = build_parser().parse_args()

    cache_dir: Path = args.cache_dir
    mode: str = args.mode
    workers = max(1, min(args.workers, 16))

    cache_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    generated_at = datetime.now(
        timezone.utc
    ).isoformat()

    if mode == "off":
        result = {
            "schema_version": 1,
            "source": "portswigger-bapp-store",
            "mode": "off",
            "generated_at": generated_at,
            "summary": {
                "official_ids": 0,
                "packages_cached": 0,
                "metadata_entries": 0,
                "failures": 0,
                "total_bytes": 0,
                "total_size": "0.00 B",
            },
            "records": [],
        }

        atomic_json_write(
            cache_dir / "manifest.json",
            result,
        )

        atomic_json_write(
            cache_dir / "unavailable.json",
            [],
        )

        write_readme(cache_dir)

        print("Official BApp cache disabled by policy")
        return 0

    print("Fetching official BApp Store index...")

    store_source = fetch_text(STORE_URL)
    uuids = parse_store_ids(store_source)

    if not uuids:
        print(
            "ERROR: no official BApp IDs found",
            file=sys.stderr,
        )
        return 1

    print(f"Official BApp IDs found: {len(uuids)}")

    records: list[dict[str, Any]] = []

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=workers,
    ) as executor:
        futures = {
            executor.submit(
                inspect_detail,
                uuid,
                cache_dir=cache_dir,
                mode=mode,
            ): uuid
            for uuid in uuids
        }

        for done, future in enumerate(
            concurrent.futures.as_completed(futures),
            start=1,
        ):
            records.append(future.result())

            if done % 10 == 0 or done == len(uuids):
                successful = sum(
                    record.get("status")
                    in {"cached", "metadata"}
                    for record in records
                )

                failed = sum(
                    record.get("status") == "error"
                    for record in records
                )

                print(
                    f"Progress: {done}/{len(uuids)} "
                    f"ok={successful} errors={failed}"
                )

    records.sort(
        key=lambda record: record["uuid"]
    )

    failures = [
        record
        for record in records
        if record.get("status") == "error"
    ]

    cached = [
        record
        for record in records
        if record.get("status") == "cached"
    ]

    metadata_entries = [
        record
        for record in records
        if record.get("status") == "metadata"
    ]

    total_bytes = sum(
        int(record.get("size_bytes") or 0)
        for record in cached
    )

    result = {
        "schema_version": 1,
        "source": "portswigger-bapp-store",
        "mode": mode,
        "generated_at": generated_at,
        "summary": {
            "official_ids": len(uuids),
            "packages_cached": len(cached),
            "metadata_entries": len(metadata_entries),
            "failures": len(failures),
            "total_bytes": total_bytes,
            "total_size": human_size(total_bytes),
        },
        "records": records,
    }

    atomic_json_write(
        cache_dir / "manifest.json",
        result,
    )

    atomic_json_write(
        cache_dir / "unavailable.json",
        failures,
    )

    write_readme(cache_dir)

    print(
        json.dumps(
            result["summary"],
            indent=2,
            sort_keys=True,
        )
    )

    if failures:
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
