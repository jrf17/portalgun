#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "lib" / "cache_sliver_armory.py"

SPEC = importlib.util.spec_from_file_location(
    "cache_sliver_armory",
    MODULE_PATH,
)
assert SPEC is not None
assert SPEC.loader is not None

cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache)


def add_bytes(
    archive: tarfile.TarFile,
    name: str,
    data: bytes,
) -> None:
    member = tarfile.TarInfo(name)
    member.size = len(data)
    archive.addfile(member, io.BytesIO(data))


def package_manifest(
    package_type: str,
    command: str,
    path: str = "payload.bin",
) -> dict:
    common = {
        "name": command,
        "command_name": command,
        "version": "v1.0.0",
        "entrypoint": "Main",
        "files": [
            {
                "os": "windows",
                "arch": "amd64",
                "path": path,
            }
        ],
    }

    if package_type == "alias":
        common.update(
            {
                "allow_args": True,
                "default_args": "",
                "is_assembly": True,
                "is_reflective": False,
            }
        )

    return common


def make_archive(
    path: Path,
    *,
    package_type: str = "extension",
    command: str = "sample",
    prefix: str = "",
    manifest: object | None = None,
    include_manifest: bool = True,
    include_payload: bool = True,
    wrong_manifest: bool = False,
    extra_members: list[tuple[str, bytes]] | None = None,
) -> None:
    if manifest is None:
        manifest = package_manifest(package_type, command)

    expected_name = (
        "extension.json"
        if package_type == "extension"
        else "alias.json"
    )
    wrong_name = (
        "alias.json"
        if package_type == "extension"
        else "extension.json"
    )

    with tarfile.open(path, "w:gz") as archive:
        if include_manifest:
            add_bytes(
                archive,
                f"{prefix}{wrong_name if wrong_manifest else expected_name}",
                json.dumps(manifest).encode(),
            )

        if include_payload:
            add_bytes(
                archive,
                f"{prefix}payload.bin",
                b"payload",
            )

        for name, data in extra_members or []:
            add_bytes(archive, name, data)


class ArchiveValidationTests(unittest.TestCase):
    def test_valid_extension(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "extension.tar.gz"
            make_archive(archive)

            manifest = cache.extract_and_validate_archive(
                archive,
                package_type="extension",
                expected_command="sample",
            )

            self.assertEqual(manifest["command_name"], "sample")

    def test_valid_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "alias.tar.gz"
            make_archive(
                archive,
                package_type="alias",
            )

            manifest = cache.extract_and_validate_archive(
                archive,
                package_type="alias",
                expected_command="sample",
            )

            self.assertTrue(manifest["is_assembly"])

    def test_harmless_dot_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "prefix.tar.gz"
            make_archive(
                archive,
                prefix="./",
            )

            cache.extract_and_validate_archive(
                archive,
                package_type="extension",
                expected_command="sample",
            )

    def test_missing_extension_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "missing.tar.gz"
            make_archive(
                archive,
                include_manifest=False,
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "expected exactly one extension.json",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_missing_alias_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "missing.tar.gz"
            make_archive(
                archive,
                package_type="alias",
                include_manifest=False,
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "expected exactly one alias.json",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="alias",
                    expected_command="sample",
                )

    def test_malformed_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "bad-json.tar.gz"

            with tarfile.open(archive, "w:gz") as handle:
                add_bytes(handle, "extension.json", b"{")
                add_bytes(handle, "payload.bin", b"payload")

            with self.assertRaisesRegex(
                cache.CacheError,
                "invalid extension.json",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_wrong_package_type(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "wrong.tar.gz"
            make_archive(
                archive,
                wrong_manifest=True,
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "wrong package type",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_missing_referenced_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "missing-payload.tar.gz"
            make_archive(
                archive,
                include_payload=False,
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "manifest references missing files",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_corrupt_archive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "corrupt.tar.gz"
            archive.write_bytes(b"not a tar archive")

            with self.assertRaisesRegex(
                cache.CacheError,
                "invalid tar.gz archive",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "traversal.tar.gz"
            make_archive(
                archive,
                extra_members=[("../escape", b"bad")],
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "unsafe archive member",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_ambiguous_normalized_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "ambiguous.tar.gz"

            with tarfile.open(archive, "w:gz") as handle:
                manifest = json.dumps(
                    package_manifest("extension", "sample")
                ).encode()
                add_bytes(handle, "extension.json", manifest)
                add_bytes(handle, "./extension.json", manifest)
                add_bytes(handle, "payload.bin", b"payload")

            with self.assertRaisesRegex(
                cache.CacheError,
                "ambiguous normalized archive path",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_command_name_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "mismatch.tar.gz"
            make_archive(
                archive,
                command="different",
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "does not match",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )


    def test_valid_multi_command_extension(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "multi.tar.gz"
            manifest = {
                "name": "Multi Command Package",
                "package_name": "multi-package",
                "version": "v1.0.0",
                "extension_author": "tester",
                "original_author": "tester",
                "repo_url": "https://github.com/sliverarmory/example",
                "commands": [
                    {
                        "command_name": "sample",
                        "entrypoint": "go",
                        "help": "sample",
                        "files": [
                            {
                                "os": "windows",
                                "arch": "amd64",
                                "path": "sample.x64.o",
                            }
                        ],
                    },
                    {
                        "command_name": "secondary",
                        "entrypoint": "go",
                        "help": "secondary",
                        "files": [
                            {
                                "os": "windows",
                                "arch": "386",
                                "path": "secondary.x86.o",
                            }
                        ],
                    },
                ],
            }

            with tarfile.open(archive, "w:gz") as handle:
                add_bytes(
                    handle,
                    "extension.json",
                    json.dumps(manifest).encode(),
                )
                add_bytes(handle, "sample.x64.o", b"sample")
                add_bytes(handle, "secondary.x86.o", b"secondary")

            result = cache.extract_and_validate_archive(
                archive,
                package_type="extension",
                expected_command="sample",
            )

            self.assertEqual(result["package_name"], "multi-package")
            self.assertEqual(len(result["commands"]), 2)

    def test_multi_command_extension_validates_all_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "multi-missing.tar.gz"
            manifest = {
                "name": "Multi Command Package",
                "package_name": "multi-package",
                "version": "v1.0.0",
                "commands": [
                    {
                        "command_name": "sample",
                        "files": [
                            {
                                "path": "sample.x64.o",
                            }
                        ],
                    },
                    {
                        "command_name": "secondary",
                        "files": [
                            {
                                "path": "missing-secondary.x86.o",
                            }
                        ],
                    },
                ],
            }

            with tarfile.open(archive, "w:gz") as handle:
                add_bytes(
                    handle,
                    "extension.json",
                    json.dumps(manifest).encode(),
                )
                add_bytes(handle, "sample.x64.o", b"sample")

            with self.assertRaisesRegex(
                cache.CacheError,
                "manifest references missing files",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )

    def test_multi_command_expected_command_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "multi-mismatch.tar.gz"
            manifest = {
                "name": "Multi Command Package",
                "package_name": "multi-package",
                "version": "v1.0.0",
                "commands": [
                    {
                        "command_name": "different",
                        "files": [
                            {
                                "path": "different.o",
                            }
                        ],
                    }
                ],
            }

            with tarfile.open(archive, "w:gz") as handle:
                add_bytes(
                    handle,
                    "extension.json",
                    json.dumps(manifest).encode(),
                )
                add_bytes(handle, "different.o", b"different")

            with self.assertRaisesRegex(
                cache.CacheError,
                "does not match expected command",
            ):
                cache.extract_and_validate_archive(
                    archive,
                    package_type="extension",
                    expected_command="sample",
                )



class CatalogTests(unittest.TestCase):
    def test_duplicate_identical_command_is_deduplicated(self) -> None:
        record = {
            "name": "LDAP Search",
            "command_name": "sa-ldapsearch",
            "repo_url": "https://github.com/sliverarmory/example",
            "public_key": "public-key",
        }
        catalog = {
            "extensions": [record, dict(record)],
            "aliases": [],
        }

        packages, summary = cache.normalize_catalog(catalog)

        self.assertEqual(len(packages), 1)
        self.assertEqual(summary["catalog_extension_records"], 2)
        self.assertEqual(summary["expected_extension_count"], 1)
        self.assertEqual(len(summary["duplicate_records"]), 1)

    def test_conflicting_duplicate_command_fails(self) -> None:
        catalog = {
            "extensions": [
                {
                    "name": "One",
                    "command_name": "duplicate",
                    "repo_url": "https://github.com/sliverarmory/one",
                    "public_key": "key-one",
                },
                {
                    "name": "Two",
                    "command_name": "duplicate",
                    "repo_url": "https://github.com/sliverarmory/two",
                    "public_key": "key-two",
                },
            ],
            "aliases": [],
        }

        with self.assertRaisesRegex(
            cache.CacheError,
            "conflicting duplicate command",
        ):
            cache.normalize_catalog(catalog)


def build_synthetic_cache(
    root: Path,
    *,
    package_type: str = "extension",
    command: str = "sample",
) -> tuple[Path, Path]:
    stage_dir = "extensions" if package_type == "extension" else "aliases"
    archive = (
        root
        / "packages"
        / stage_dir
        / command
        / "v1.0.0"
        / f"{command}.tar.gz"
    )
    signature = archive.with_name(f"{command}.minisig")
    staged = root / stage_dir / command

    archive.parent.mkdir(parents=True, exist_ok=True)
    make_archive(
        archive,
        package_type=package_type,
        command=command,
    )
    signature.write_bytes(b"synthetic signature")

    manifest = cache.extract_and_validate_archive(
        archive,
        package_type=package_type,
        expected_command=command,
        destination=staged,
    )
    inventory = cache.package_tree_inventory(staged)

    extension_count = 1 if package_type == "extension" else 0
    alias_count = 1 if package_type == "alias" else 0

    record = {
        "type": package_type,
        "name": command,
        "command_name": command,
        "repo_url": "https://github.com/sliverarmory/example",
        "public_key": "synthetic-key",
        "status": "cached",
        "release_tag": "v1.0.0",
        "archive_url": "synthetic",
        "signature_url": "synthetic",
        "archive": str(archive.relative_to(root)),
        "signature": str(signature.relative_to(root)),
        "staged_path": str(staged.relative_to(root)),
        "archive_sha256": cache.sha256_file(archive),
        "archive_size_bytes": archive.stat().st_size,
        "signature_sha256": cache.sha256_file(signature),
        "signature_size_bytes": signature.stat().st_size,
        "content_file_count": len(inventory),
        "content_files": inventory,
        "version": manifest.get("version"),
        "downloaded": False,
    }

    cache.atomic_json_write(
        root / "manifest.json",
        {
            "schema_version": cache.SCHEMA_VERSION,
            "generated_at": cache.utc_now(),
            "source": {
                "repository": cache.OFFICIAL_REPOSITORY,
                "release_tag": "synthetic",
            },
            "mode": "preseed",
            "status": "complete",
            "catalog_extension_records": extension_count,
            "catalog_alias_records": alias_count,
            "expected_extension_count": extension_count,
            "expected_alias_count": alias_count,
            "duplicate_records": [],
            "cached_extension_count": extension_count,
            "cached_alias_count": alias_count,
            "package_count": 1,
            "total_bytes": (
                archive.stat().st_size + signature.stat().st_size
            ),
            "failures": [],
            "packages": [record],
        },
    )

    cache.normalize_staged_tree_permissions(root)

    return staged, archive


class ReleaseResolutionTests(unittest.TestCase):
    def test_semver_patch_release_candidates(self) -> None:
        self.assertEqual(
            cache.release_tag_candidates("v0.1.3"),
            ["v0.1.3", "v0.1.2", "v0.1.1", "v0.1.0"],
        )

    def test_non_semver_release_has_no_fallback_guess(self) -> None:
        self.assertEqual(
            cache.release_tag_candidates("latest-stable"),
            ["latest-stable"],
        )


class CacheManifestTests(unittest.TestCase):
    def test_complete_synthetic_cache_validates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_synthetic_cache(root)

            summary = cache.validate_cache(root)

            self.assertEqual(summary["status"], "complete")
            self.assertEqual(summary["cached_extension_count"], 1)
            self.assertEqual(summary["cached_alias_count"], 0)

    def test_modified_staged_payload_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staged, _ = build_synthetic_cache(root)
            (staged / "payload.bin").write_bytes(b"modified")

            with self.assertRaisesRegex(
                cache.CacheError,
                "staged content inventory mismatch",
            ):
                cache.validate_cache(root)

    def test_modified_archive_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, archive = build_synthetic_cache(root)
            archive.write_bytes(b"corrupt")

            with self.assertRaisesRegex(
                cache.CacheError,
                "archive digest mismatch",
            ):
                cache.validate_cache(root)

    def test_exact_count_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_synthetic_cache(root)

            manifest_path = root / "manifest.json"
            manifest = json.loads(
                manifest_path.read_text(encoding="utf-8")
            )
            manifest["expected_extension_count"] = 2
            cache.atomic_json_write(manifest_path, manifest)

            with self.assertRaisesRegex(
                cache.CacheError,
                "extension count mismatch",
            ):
                cache.validate_cache(root)

    def test_duplicate_manifest_record_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_synthetic_cache(root)

            manifest_path = root / "manifest.json"
            manifest = json.loads(
                manifest_path.read_text(encoding="utf-8")
            )
            manifest["packages"].append(dict(manifest["packages"][0]))
            cache.atomic_json_write(manifest_path, manifest)

            with self.assertRaisesRegex(
                cache.CacheError,
                "duplicate package record",
            ):
                cache.validate_cache(root)


class StagedTreeTests(unittest.TestCase):
    def test_valid_staged_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "payload.bin").write_bytes(b"payload")
            (root / "extension.json").write_text(
                json.dumps(
                    package_manifest("extension", "sample")
                ),
                encoding="utf-8",
            )

            manifest = cache.inspect_package_tree(
                root,
                package_type="extension",
                expected_command="sample",
            )

            self.assertEqual(manifest["command_name"], "sample")

    def test_wrong_staged_type_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "payload.bin").write_bytes(b"payload")
            (root / "alias.json").write_text(
                json.dumps(
                    package_manifest("alias", "sample")
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                cache.CacheError,
                "wrong package type",
            ):
                cache.inspect_package_tree(
                    root,
                    package_type="extension",
                    expected_command="sample",
                )


class StagedPermissionTests(unittest.TestCase):
    def test_normalize_staged_tree_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            extension_root = root / "extensions"
            alias_root = root / "aliases"
            extension = extension_root / "sample"
            alias = alias_root / "sample"

            extension.mkdir(parents=True)
            alias.mkdir(parents=True)

            extension_manifest = extension / "extension.json"
            alias_manifest = alias / "alias.json"

            extension_manifest.write_text("{}", encoding="utf-8")
            alias_manifest.write_text("{}", encoding="utf-8")

            extension_root.chmod(0o700)
            alias_root.chmod(0o700)
            extension.chmod(0o700)
            alias.chmod(0o700)
            extension_manifest.chmod(0o600)
            alias_manifest.chmod(0o600)

            cache.normalize_staged_tree_permissions(root)
            cache.validate_staged_tree_permissions(root)

            self.assertEqual(
                extension_root.stat().st_mode & 0o777,
                0o755,
            )
            self.assertEqual(
                alias_root.stat().st_mode & 0o777,
                0o755,
            )
            self.assertEqual(
                extension.stat().st_mode & 0o777,
                0o755,
            )
            self.assertEqual(
                alias.stat().st_mode & 0o777,
                0o755,
            )
            self.assertEqual(
                extension_manifest.stat().st_mode & 0o777,
                0o644,
            )
            self.assertEqual(
                alias_manifest.stat().st_mode & 0o777,
                0o644,
            )

    def test_private_staged_directory_fails_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            extension = root / "extensions" / "sample"

            extension.mkdir(parents=True)
            (root / "aliases").mkdir()
            (extension / "extension.json").write_text(
                "{}",
                encoding="utf-8",
            )
            extension.chmod(0o700)

            with self.assertRaisesRegex(
                cache.CacheError,
                "target-user traversable",
            ):
                cache.validate_staged_tree_permissions(root)

    def test_private_staged_file_fails_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            extension = root / "extensions" / "sample"

            extension.mkdir(parents=True)
            (root / "aliases").mkdir()

            manifest = extension / "extension.json"
            manifest.write_text("{}", encoding="utf-8")
            manifest.chmod(0o600)

            with self.assertRaisesRegex(
                cache.CacheError,
                "target-user readable",
            ):
                cache.validate_staged_tree_permissions(root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
