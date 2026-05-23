#!/usr/bin/env python3
"""
Append a portalgun-registered GitHub tool to install_github_tools.sh's TOOLS array.
Idempotent. Uses managed markers inside the TOOLS=( ... ) block.
"""
import json
import re
import sys
from pathlib import Path

MARK_START = "    # PORTALGUN_MANAGED_START — do not hand-edit between these markers"
MARK_END = "    # PORTALGUN_MANAGED_END"


def main(script_path: str, json_path: str) -> int:
    script = Path(script_path)
    if not script.is_file():
        print(f"script not found: {script}", file=sys.stderr)
        return 1

    data = json.loads(Path(json_path).read_text())
    name = data["name"]
    repo = data["repo"]
    os_field = data.get("os", "misc") or "misc"
    cat_field = data.get("category", "misc") or "misc"
    lang = data.get("language", "none")
    build_cmd = data.get("build_cmd", "") or ""
    target = data.get("target", "")

    # Decide needs_compile: never for windows targets, otherwise true iff language detected
    if "/windows/" in target or os_field == "windows":
        needs_compile = "false"
        build_cmd = ""
    elif lang and lang != "none":
        needs_compile = "true"
    else:
        needs_compile = "false"
        build_cmd = ""

    # Format matches existing install_github_tools.sh TOOLS array entries
    entry = f'    "{name}|{repo}|{cat_field}|{os_field}|CLONE|{needs_compile}|{build_cmd}"'

    content = script.read_text()

    # Skip if entry already present (by name|repo prefix)
    needle = f'"{name}|{repo}|'
    if needle in content:
        return 0

    # Ensure managed block exists inside TOOLS=( ... )
    if MARK_START not in content:
        # Find TOOLS=( and its matching closing line `)` at column 0
        m = re.search(r'^TOOLS=\(', content, flags=re.MULTILINE)
        if not m:
            print("could not find TOOLS=( array in script", file=sys.stderr)
            return 2
        start_idx = m.end()
        # Find the closing ) on its own line
        close_match = re.search(r'^\)\s*$', content[start_idx:], flags=re.MULTILINE)
        if not close_match:
            print("could not find closing ) of TOOLS array", file=sys.stderr)
            return 3
        insert_at = start_idx + close_match.start()
        content = (
            content[:insert_at]
            + MARK_START + "\n"
            + MARK_END + "\n"
            + content[insert_at:]
        )

    # Insert entry before the END marker
    end_idx = content.index(MARK_END)
    content = content[:end_idx] + entry + "\n" + content[end_idx:]

    script.write_text(content)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: sync_github.py <install_github_tools.sh> <registry-json>", file=sys.stderr)
        sys.exit(64)
    sys.exit(main(sys.argv[1], sys.argv[2]))
