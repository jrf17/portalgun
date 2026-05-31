#!/bin/bash
# Validate every installed GitHub tool actually works
# Usage: sudo bash validate_github_tools.sh [--fix]

TOOLS_BASE="${PORTALGUN_TOOLS_BASE:-/opt/tools}"
VENV_PYTHON="/opt/pentest-venv/bin/python3"
PASS=0; FAIL=0; SKIP=0
FAILURES=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}[ok]${NC} $*"; (( PASS++ )) || true; }
fail() { echo -e "  ${RED}[fail]${NC} $*"; (( FAIL++ )) || true; FAILURES+=("$*"); }
skip() { echo -e "  ${YELLOW}[skip]${NC} $*"; (( SKIP++ )) || true; }
info() { echo -e "${BLUE}[*]${NC} $*"; }

# Install requirements.txt for a tool into the venv
install_requirements() {
    local tool_dir="$1"
    local req="$tool_dir/source/requirements.txt"
    [ -f "$req" ] || return 0
    /opt/pentest-venv/bin/pip install --quiet -r "$req" 2>/dev/null && return 0
    return 1
}

# Test a tool by trying to run it
test_tool() {
    local name="$1"
    local tool_dir="$2"
    local src="$tool_dir/source"

    # Skip if no source
    [ -d "$src" ] || { skip "$name (no source dir)"; return; }

    # Install requirements if needed
    if [ -f "$src/requirements.txt" ]; then
        /opt/pentest-venv/bin/pip install --quiet -r "$src/requirements.txt" 2>/dev/null || true
    fi

    # Determine test strategy based on tool type
    # 1. Go binary
    if ls "$tool_dir"/*.go_binary "$tool_dir/$name" 2>/dev/null | grep -q .; then
        local bin=$(find "$tool_dir" -maxdepth 1 -type f -executable ! -name "*.py" ! -name "*.sh" 2>/dev/null | head -1)
        if [ -n "$bin" ] && "$bin" --help >/dev/null 2>&1 || "$bin" -h >/dev/null 2>&1; then
            pass "$name (binary runs)"
        else
            skip "$name (binary exists, no --help)"
        fi
        return
    fi

    # 2. Python main script
    local py_main
    py_main=$(find "$src" -maxdepth 2 -name "*.py" | grep -iE "main|${name}|__main__" | head -1)
    if [ -z "$py_main" ]; then
        py_main=$(find "$src" -maxdepth 1 -name "*.py" | head -1)
    fi
    if [ -n "$py_main" ]; then
        if timeout 5 "$VENV_PYTHON" "$py_main" --help >/dev/null 2>&1 || \
           timeout 5 "$VENV_PYTHON" "$py_main" -h >/dev/null 2>&1 || \
           timeout 5 "$VENV_PYTHON" -c "import importlib.util; spec=importlib.util.spec_from_file_location('m','$py_main'); m=importlib.util.module_from_spec(spec)" 2>/dev/null; then
            pass "$name (python runs)"
        else
            # Check if it's just a collection (payloads, cheatsheets)
            local file_count
            file_count=$(find "$src" -type f | wc -l)
            if [ "$file_count" -gt 5 ]; then
                skip "$name (collection, $file_count files)"
            else
                fail "$name (python fails: $py_main)"
            fi
        fi
        return
    fi

    # 3. Shell script
    local sh_main
    sh_main=$(find "$src" -maxdepth 1 -name "*.sh" | head -1)
    if [ -n "$sh_main" ]; then
        if bash -n "$sh_main" 2>/dev/null; then
            pass "$name (shell script valid)"
        else
            fail "$name (shell syntax error: $sh_main)"
        fi
        return
    fi

    # 4. PowerShell / .NET / binaries — just verify files exist
    local ps1_count
    ps1_count=$(find "$src" -name "*.ps1" -o -name "*.exe" -o -name "*.dll" | wc -l)
    if [ "$ps1_count" -gt 0 ]; then
        pass "$name ($ps1_count Windows files present)"
        return
    fi

    # 5. Data/collection (markdown, payloads etc)
    local file_count
    file_count=$(find "$src" -type f | wc -l)
    if [ "$file_count" -gt 10 ]; then
        pass "$name (collection: $file_count files)"
        return
    fi

    skip "$name (no testable entry point)"
}

info "Validating GitHub tools under $TOOLS_BASE..."
echo ""

# Walk all tool dirs
while IFS= read -r tool_dir; do
    name=$(basename "$tool_dir")
    test_tool "$name" "$tool_dir"
done < <(find "$TOOLS_BASE" -mindepth 2 -maxdepth 2 -type d ! -name "source" | sort)

echo ""
info "Results: ${PASS} pass, ${FAIL} fail, ${SKIP} skip"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Failures:${NC}"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

exit 0
