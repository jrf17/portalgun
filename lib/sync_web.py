#!/usr/bin/env python3
"""
Walk the portalgun registry and emit a single JSON manifest
for the web UI to consume.
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def main(registry_dir: str, out_file: str) -> int:
    registry = Path(registry_dir)
    tools = {"apt": [], "github": []}

    for kind in ("apt", "github"):
        type_dir = registry / kind
        if not type_dir.is_dir():
            continue
        for f in sorted(type_dir.glob("*.json")):
            try:
                tools[kind].append(json.loads(f.read_text()))
            except Exception as e:
                print(f"warn: could not parse {f}: {e}", file=sys.stderr)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "totals": {
            "apt": len(tools["apt"]),
            "github": len(tools["github"]),
            "total": len(tools["apt"]) + len(tools["github"]),
        },
        "tools": tools,
    }

    out = Path(out_file)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: sync_web.py <registry-dir> <out-file>", file=sys.stderr)
        sys.exit(64)
    sys.exit(main(sys.argv[1], sys.argv[2]))
