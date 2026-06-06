#!/usr/bin/env python3
"""
Walk the portalgun registry and emit a single JSON manifest
for the web UI to consume.
"""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def find_github_readme(tool_dir: str) -> str:
    """Find a README file inside source/ — return absolute path."""
    if not tool_dir:
        return ""
    src = Path(tool_dir) / "source"
    if not src.is_dir():
        return ""
    candidates = ["README.md", "Readme.md", "readme.md", "README.MD",
                  "README.rst", "README.txt", "README"]
    for name in candidates:
        p = src / name
        if p.is_file():
            return str(p)
    for p in src.glob("[Rr][Ee][Aa][Dd][Mm][Ee]*"):
        if p.is_file():
            return str(p)
    return ""


def find_apt_readme(package: str) -> dict:
    """Find a README for an apt package.

    Returns dict with 'kind' (doc-file|manpage|help-text) and 'path' or 'package'.
    Only returns a result for "hacking tools" — apt packages that ship a binary
    in PATH (filters out system libs, fonts, etc.).
    """
    if not package:
        return {}

    doc_dir = Path(f"/usr/share/doc/{package}")
    if doc_dir.is_dir():
        for candidate in ("README.md", "README.rst", "README.txt", "README",
                          "README.Debian", "README.Debian.gz",
                          "README.md.gz", "README.gz"):
            p = doc_dir / candidate
            if p.is_file():
                return {"kind": "doc-file", "path": str(p)}
        # Glob
        for p in doc_dir.glob("[Rr][Ee][Aa][Dd][Mm][Ee]*"):
            if p.is_file():
                return {"kind": "doc-file", "path": str(p)}

    has_binary = False
    try:
        result = subprocess.run(
            ["dpkg", "-L", package],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith(("/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/")):
                has_binary = True
                break
    except Exception:
        pass

    if not has_binary:
        return {}

    try:
        result = subprocess.run(
            ["man", "-w", package],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return {"kind": "manpage", "package": package}
    except Exception:
        pass

    return {"kind": "help-text", "package": package}


def main(registry_dir: str, out_file: str) -> int:
    registry = Path(registry_dir)
    tools = {"apt": [], "github": []}

    for kind in ("apt", "github"):
        type_dir = registry / kind
        if not type_dir.is_dir():
            continue
        for f in sorted(type_dir.glob("*.json")):
            try:
                entry = json.loads(f.read_text())
                if kind == "github":
                    readme_path = find_github_readme(entry.get("tool_dir", ""))
                    if readme_path:
                        entry["readme_path"] = readme_path
                elif kind == "apt":
                    readme = find_apt_readme(entry.get("package", ""))
                    if readme:
                        entry["readme"] = readme
                tools[kind].append(entry)
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
