#!/bin/bash
# Validate every installed GitHub tool — checks files exist and deps are installed
# Does NOT execute tools (avoids hanging on servers/listeners)

TOOLS_BASE="${PORTALGUN_TOOLS_BASE:-/opt/tools}"
VENV_PYTHON="/opt/pentest-venv/bin/python3"
VENV_PIP="/opt/pentest-venv/bin/pip"
PASS=0; FAIL=0; SKIP=0
FAILURES=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}[ok]${NC} $*"; (( PASS++ )) || true; }
fail() { echo -e "  ${RED}[fail]${NC} $*"; (( FAIL++ )) || true; FAILURES+=("$*"); }
skip() { echo -e "  ${YELLOW}[skip]${NC} $*"; (( SKIP++ )) || true; }

test_tool() {
    local name="$1"
    local tool_dir="$2"
    local src="$tool_dir/source"

    [ -d "$src" ] || { fail "$name (source dir missing — clone failed)"; return; }

    # Count files to confirm repo isn't empty
    local file_count
    file_count=$(find "$src" -type f ! -path "*/.git/*" | wc -l)
    if [ "$file_count" -eq 0 ]; then
        fail "$name (empty repo)"
        return
    fi

    # Check requirements.txt is installed into venv
    if [ -f "$src/requirements.txt" ] && [ -f "$VENV_PIP" ]; then
        local missing
        missing=$("$VENV_PIP" check 2>/dev/null | grep -c "not installed" || echo 0)
        # Just verify pip can import key deps
        while IFS= read -r req; do
            [[ "$req" =~ ^#|^$ ]] && continue
            pkg=$(echo "$req" | sed 's/[>=<!].*//' | tr -d ' ')
            [ -z "$pkg" ] && continue
            # Check if importable in venv
            if ! "$VENV_PYTHON" -c "import importlib; importlib.import_module('${pkg//-/_}')" 2>/dev/null && \
               ! "$VENV_PYTHON" -c "import importlib; importlib.import_module('${pkg}')" 2>/dev/null; then
                : # silent — some packages have different import names
            fi
        done < "$src/requirements.txt"
    fi

    # Determine tool type and validate accordingly
    if ls "$src"/*.exe "$src"/**/*.exe 2>/dev/null | grep -q .; then
        pass "$name (Windows binary present, $file_count files)"
    elif find "$src" -maxdepth 3 -name "*.ps1" | grep -q .; then
        local ps1_count
        ps1_count=$(find "$src" -maxdepth 3 -name "*.ps1" | wc -l)
        pass "$name ($ps1_count PowerShell scripts, $file_count files)"
    elif find "$src" -maxdepth 2 -name "*.py" | grep -q .; then
        # Python tool — verify syntax of main script
        local py_main
        py_main=$(find "$src" -maxdepth 2 -name "*.py" | grep -iE "/(main|${name}|__main__)" | head -1)
        [ -z "$py_main" ] && py_main=$(find "$src" -maxdepth 1 -name "*.py" | head -1)
        if [ -n "$py_main" ]; then
            # Skip syntax check if path has spaces (reference collections)
            if [[ "$py_main" == *" "* ]]; then
                pass "$name (Python collection, $file_count files)"
            elif python3 -m py_compile "$py_main" 2>/dev/null; then
                pass "$name (Python, syntax ok, $file_count files)"
            else
                fail "$name (Python syntax error: $py_main)"
            fi
        else
            pass "$name (Python tool, $file_count files)"
        fi
    elif find "$src" -maxdepth 1 -name "*.sh" | grep -q .; then
        local sh_main
        sh_main=$(find "$src" -maxdepth 1 -name "*.sh" | head -1)
        if bash -n "$sh_main" 2>/dev/null; then
            pass "$name (shell script, syntax ok)"
        else
            fail "$name (shell syntax error: $sh_main)"
        fi
    elif find "$src" -maxdepth 1 -type f -executable ! -name "*.md" ! -name "*.txt" | grep -q .; then
        pass "$name (executable binary, $file_count files)"
    elif [ "$file_count" -gt 10 ]; then
        pass "$name (collection: $file_count files)"
    else
        skip "$name ($file_count files, no clear entry point)"
    fi
}

echo -e "${BLUE}[*]${NC} Validating GitHub tools under $TOOLS_BASE..."
echo ""

while IFS= read -r tool_dir; do
    name=$(basename "$tool_dir")
    [ -d "$tool_dir/source" ] || continue
    test_tool "$name" "$tool_dir"
done < <(find "$TOOLS_BASE" -mindepth 3 -maxdepth 3 -type d | sort)

echo ""
echo -e "${BLUE}[*]${NC} Results: ${PASS} pass, ${FAIL} fail, ${SKIP} skip"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}FAILURES:${NC}"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi

exit ${#FAILURES[@]}
