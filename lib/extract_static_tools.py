#!/usr/bin/env python3
"""Extract toolsData entries from tools_readme.html into /tmp/static_tools.json.

Parses the embedded JS toolsData array literal and emits a flat list of objects:
  [{name, type, path?, desc, category}, ...]

Run: python3 extract_static_tools.py [path/to/tools_readme.html]
"""
import json
import re
import sys
from pathlib import Path

DEFAULT_HTML = Path("/opt/tools-docs/tools_readme.html")


def parse_object_literal(src: str, start: int):
    """Parse a JS object literal starting at src[start] == '{'. Returns (obj, end_idx)."""
    assert src[start] == '{'
    depth = 0
    i = start
    in_str = False
    str_ch = ''
    while i < len(src):
        ch = src[i]
        if in_str:
            if ch == '\\':
                i += 2
                continue
            if ch == str_ch:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'", '`'):
            in_str = True
            str_ch = ch
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return src[start:i+1], i+1
        i += 1
    return None, len(src)


def js_obj_to_py(js_obj: str) -> dict:
    """Very small JS-object-literal → dict converter. Handles name:, type:, path:, desc:, category:."""
    out = {}
    # Match key: "value" or key: 'value'
    for m in re.finditer(r'(\w+)\s*:\s*(["\'])((?:\\.|(?!\2).)*)\2', js_obj):
        key, _, val = m.group(1), m.group(2), m.group(3)
        out[key] = val.replace("\\'", "'").replace('\\"', '"').replace('\\\\', '\\')
    return out


def main() -> int:
    src_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_HTML
    if not src_path.is_file():
        print(f"Missing {src_path}", file=sys.stderr)
        return 1

    html = src_path.read_text(encoding='utf-8', errors='replace')

    # Find the toolsData array literal.
    # Match: const toolsData = [   or   toolsData = [
    m = re.search(r'(?:const\s+|let\s+|var\s+)?toolsData\s*=\s*\[', html)
    if not m:
        print("toolsData array not found", file=sys.stderr)
        return 1

    array_start = m.end() - 1  # index of '['
    # Walk to matching ']' at depth 0 (respecting strings)
    depth = 0
    i = array_start
    in_str = False
    str_ch = ''
    while i < len(html):
        ch = html[i]
        if in_str:
            if ch == '\\':
                i += 2
                continue
            if ch == str_ch:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'", '`'):
            in_str = True
            str_ch = ch
        elif ch == '[':
            depth += 1
        elif ch == ']':
            depth -= 1
            if depth == 0:
                break
        i += 1

    body = html[array_start+1:i]
    # Find each top-level '{ ... }'
    tools = []
    j = 0
    while j < len(body):
        if body[j] == '{':
            obj_src, j = parse_object_literal(body, j)
            if obj_src is None:
                break
            obj = js_obj_to_py(obj_src)
            if obj.get('name') and obj.get('type'):
                tools.append(obj)
        else:
            j += 1

    out_path = Path('/tmp/static_tools.json')
    out_path.write_text(json.dumps(tools, indent=2))
    print(f"Extracted {len(tools)} tools → {out_path}")

    # Per-type breakdown
    by_type = {}
    for t in tools:
        by_type[t['type']] = by_type.get(t['type'], 0) + 1
    for k, v in sorted(by_type.items()):
        print(f"  {k}: {v}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
