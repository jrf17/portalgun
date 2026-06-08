#!/usr/bin/env python3
"""
For every static tool in /tmp/static_tools.json that DOESN'T already have a
cached README, write a minimal synthetic README from the tool's metadata
(name, type, path, desc, tags). Guarantees 100% offline coverage.

Run AFTER fetch_static_readmes.py. Reads/writes the same map file so the
manifest sees a single unified mapping.

Env:
  PG_STATIC_CACHE  (default /var/cache/portalgun/static-readmes)
  PG_STATIC_MAP    (default /var/cache/portalgun/static-tools-map.json)
  PG_STATIC_TOOLS  (default /tmp/static_tools.json)
"""
import json
import os
import re
import sys
from pathlib import Path

CACHE_DIR = Path(os.environ.get("PG_STATIC_CACHE", "/var/cache/portalgun/static-readmes"))
MAPPING_FILE = Path(os.environ.get("PG_STATIC_MAP", "/var/cache/portalgun/static-tools-map.json"))
STATIC_TOOLS = Path(os.environ.get("PG_STATIC_TOOLS", "/tmp/static_tools.json"))


def safe_name(name: str) -> str:
    return re.sub(r'[^A-Za-z0-9_-]', '_', name).lower()


TYPE_LABEL = {
    "apt": "APT Package",
    "github": "GitHub Project",
    "pip": "Python Package (pip)",
    "pipx": "Python Application (pipx)",
    "gem": "Ruby Gem",
}


def stub_for(tool: dict) -> str:
    name = tool.get("name", "?")
    typ = tool.get("type", "")
    path = tool.get("path", "")
    desc = tool.get("desc", "")
    cat = tool.get("cat", "")
    tags = tool.get("tags", "")
    if isinstance(tags, str):
        tag_list = [t.strip() for t in re.split(r'[,\s]+', tags) if t.strip()]
    else:
        tag_list = list(tags) if tags else []

    parts = [f"# {name}"]
    if desc:
        parts.append(f"\n{desc}\n")

    parts.append("## Overview\n")
    rows = []
    if typ:
        rows.append(f"- **Source type**: {TYPE_LABEL.get(typ, typ.upper())}")
    if path:
        if typ == "apt":
            rows.append(f"- **Package name**: `{path}`")
            rows.append(f"- **Install**: `sudo apt install {path}`")
        elif typ in ("pip", "pipx"):
            rows.append(f"- **Module**: `{path}`")
            rows.append(f"- **Install**: `{typ} install {path}`")
        elif typ == "gem":
            rows.append(f"- **Gem**: `{path}`")
            rows.append(f"- **Install**: `gem install {path}`")
        else:
            rows.append(f"- **Location**: `{path}`")
    if cat:
        rows.append(f"- **Category**: {cat}")
    if tag_list:
        rows.append(f"- **Tags**: {', '.join(f'`{t}`' for t in tag_list)}")
    parts.append("\n".join(rows))

    parts.append(
        "\n\n---\n\n"
        "_This is an offline reference stub generated from the Portalgun tool "
        "catalog. The upstream project's README was not pre-cached or could "
        "not be retrieved at build time._\n"
    )
    return "\n".join(parts)


def main() -> int:
    if not STATIC_TOOLS.is_file():
        print(f"Missing {STATIC_TOOLS}", file=sys.stderr)
        return 1
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    with STATIC_TOOLS.open() as f:
        tools = json.load(f)

    mapping = {}
    if MAPPING_FILE.is_file():
        try:
            mapping = json.loads(MAPPING_FILE.read_text())
        except Exception:
            mapping = {}

    added = 0
    kept = 0
    for tool in tools:
        name = tool.get("name")
        if not name:
            continue
        existing = mapping.get(name)
        if existing and Path(existing.get("readme_path", "")).is_file():
            kept += 1
            continue
        out_path = CACHE_DIR / f"{safe_name(name)}.md"
        out_path.write_text(stub_for(tool), encoding="utf-8")
        mapping[name] = {"readme_path": str(out_path), "repo_url": "", "stub": True}
        added += 1

    MAPPING_FILE.write_text(json.dumps(mapping, indent=2))
    print(f"DONE: {added} stubs written, {kept} real READMEs kept, {len(mapping)} total mapped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
