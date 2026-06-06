#!/usr/bin/env python3
"""
Walk the portalgun registry and emit a single JSON manifest
for the web UI to consume.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

README_CACHE = Path("/var/cache/portalgun/apt-readmes")


def find_github_readme(tool_dir: str) -> str:
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


# Heuristic to decide if an apt package is "an actual tool" worth READMEs for
EXCLUDE_PREFIXES = (
    "lib",        # libraries
    "python3-",   # python deps
    "ruby-",      # ruby deps
    "node-",      # node deps
    "golang-",    # go deps
    "rust-",      # rust deps
    "perl-",
    "gcc-",
    "g++",
    "binutils-",
    "linux-headers",
    "linux-image",
    "linux-libc-dev",
    "linux-tools",
    "fonts-",
    "icu-",
    "ttf-",
    "xfonts-",
    "openjdk-",
    "openssl-",
)

EXCLUDE_SUFFIXES = (
    "-dev",
    "-doc",
    "-data",
    "-common",
    "-locales",
    "-dbg",
    "-dbgsym",
    "-doc-html",
    "-perl",
    "-tools",      # not always but mostly meta packages
)

EXCLUDE_EXACT = {
    "build-essential", "dpkg", "apt", "make", "cmake", "automake",
    "autoconf", "pkg-config", "git", "curl", "wget", "vim", "neovim",
    "tmux", "kitty", "starship", "fzf", "zoxide", "eza", "bat", "btop",
    "atuin", "lazygit", "delta", "sd", "ripgrep", "fd-find", "jq",
    "rsync", "xclip", "fontconfig", "zellij", "yazi", "lazydocker",
    "ca-certificates", "openssh-client", "openssh-server", "sudo",
    "bash", "zsh", "coreutils", "util-linux", "findutils", "grep", "sed",
    "gawk", "tar", "gzip", "bzip2", "xz-utils", "unzip", "p7zip",
    "lsb-release", "software-properties-common", "gnupg", "gpg",
    "iputils-ping", "iproute2", "net-tools", "dnsutils",
    "ntpsec", "ntpsec-ntpdate", "ntpsec-ntpdig",
    "obsidian", "firefox-esr", "thunderbird",
    "neo4j",  # database, not a tool
    "ghidra-data",  # data file
    "ghidra",  # too heavy + we cover this differently
}


def is_actual_tool(package: str) -> bool:
    """Heuristic — is this apt package worth showing a README for?"""
    if not package:
        return False
    if package in EXCLUDE_EXACT:
        return False
    pkg_lower = package.lower()
    for prefix in EXCLUDE_PREFIXES:
        if pkg_lower.startswith(prefix):
            return False
    for suffix in EXCLUDE_SUFFIXES:
        if pkg_lower.endswith(suffix):
            return False
    # Must have a binary in PATH to count as a "tool"
    try:
        r = subprocess.run(["dpkg", "-L", package], capture_output=True, text=True, timeout=3)
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith(("/usr/bin/", "/usr/sbin/")):
                return True
    except Exception:
        pass
    return False


def get_homepage(package: str) -> str:
    """Get Homepage: field from apt-cache show, prefer github URLs."""
    try:
        r = subprocess.run(["apt-cache", "show", package], capture_output=True, text=True, timeout=3)
        homepages = []
        for line in r.stdout.splitlines():
            if line.startswith("Homepage:"):
                url = line.split(":", 1)[1].strip()
                homepages.append(url)
        # Prefer GitHub, GitLab, etc.
        for url in homepages:
            if "github.com" in url.lower() or "gitlab.com" in url.lower():
                return url
        return homepages[0] if homepages else ""
    except Exception:
        return ""


def github_url_to_raw_readme(url: str) -> list:
    """Convert https://github.com/owner/repo → list of raw README URL candidates."""
    m = re.match(r"https?://github\.com/([^/]+)/([^/?#]+)", url)
    if not m:
        return []
    owner, repo = m.group(1), m.group(2)
    repo = re.sub(r"\.git$", "", repo)
    return [
        f"https://raw.githubusercontent.com/{owner}/{repo}/HEAD/README.md",
        f"https://raw.githubusercontent.com/{owner}/{repo}/main/README.md",
        f"https://raw.githubusercontent.com/{owner}/{repo}/master/README.md",
        f"https://raw.githubusercontent.com/{owner}/{repo}/HEAD/Readme.md",
        f"https://raw.githubusercontent.com/{owner}/{repo}/HEAD/readme.md",
    ]


def fetch_and_cache_readme(package: str, homepage: str) -> str:
    """Try to download the GitHub README for an apt package, cache to disk.
    Returns local path on success, empty string on failure.
    """
    README_CACHE.mkdir(parents=True, exist_ok=True)
    cache_file = README_CACHE / f"{package}.md"
    if cache_file.is_file() and cache_file.stat().st_size > 100:
        return str(cache_file)

    candidates = github_url_to_raw_readme(homepage)
    if not candidates:
        return ""

    for url in candidates:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "portalgun/1.0"})
            with urllib.request.urlopen(req, timeout=5) as r:
                if r.status == 200:
                    content = r.read()
                    if len(content) > 100:
                        cache_file.write_bytes(content)
                        return str(cache_file)
        except Exception:
            continue
    return ""


def main(registry_dir: str, out_file: str) -> int:
    registry = Path(registry_dir)
    tools = {"apt": [], "github": []}
    offline_only = os.environ.get("PORTALGUN_OFFLINE", "") == "1"

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
                    pkg = entry.get("package", "")
                    if is_actual_tool(pkg):
                        homepage = get_homepage(pkg)
                        if homepage:
                            entry["homepage"] = homepage
                        # Try GitHub README first
                        if not offline_only and homepage:
                            cached = fetch_and_cache_readme(pkg, homepage)
                            if cached:
                                entry["readme"] = {"kind": "doc-file", "path": cached, "source": "github"}
                        # Else fall back to /usr/share/doc README
                        if "readme" not in entry:
                            doc_dir = Path(f"/usr/share/doc/{pkg}")
                            if doc_dir.is_dir():
                                for c in ("README.md", "README.rst", "README.txt", "README",
                                          "README.Debian", "README.md.gz", "README.gz"):
                                    p = doc_dir / c
                                    if p.is_file():
                                        entry["readme"] = {"kind": "doc-file", "path": str(p), "source": "system"}
                                        break
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
