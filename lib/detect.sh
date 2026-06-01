#!/bin/bash
# portalgun build-system detection + dependency management

# Returns "language|build_cmd" on stdout
detect_build() {
    local dir="$1"
    local name=$(basename "$(dirname "$dir")")  # tool name (parent of source/)

    if [ -f "$dir/Cargo.toml" ]; then
        echo "rust|cargo build --release"; return 0
    fi
    if [ -f "$dir/go.mod" ]; then
        echo "go|go build -o $name ./..."; return 0
    fi
    if [ -f "$dir/pom.xml" ]; then
        echo "maven|mvn -q package -DskipTests"; return 0
    fi
    if [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; then
        echo "gradle|gradle -q build -x test"; return 0
    fi
    if [ -f "$dir/CMakeLists.txt" ]; then
        echo "cmake|cmake -B build && cmake --build build"; return 0
    fi
    if [ -x "$dir/configure" ]; then
        echo "autotools|./configure && make"; return 0
    fi
    if [ -f "$dir/Makefile" ] || [ -f "$dir/makefile" ] || [ -f "$dir/GNUmakefile" ]; then
        echo "make|make"; return 0
    fi
    if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
        echo "python|/opt/pentest-venv/bin/pip install --quiet ."; return 0
    fi
    if [ -f "$dir/requirements.txt" ]; then
        echo "python-req|/opt/pentest-venv/bin/pip install --quiet -r requirements.txt"; return 0
    fi
    if ls "$dir"/*.sln >/dev/null 2>&1; then
        echo "dotnet|dotnet build -c Release --nologo 2>&1 | tail -5"; return 0
    fi
    if ls "$dir"/*.csproj >/dev/null 2>&1; then
        echo "dotnet|dotnet build -c Release --nologo 2>&1 | tail -5"; return 0
    fi
    # Single .cs file — compile with mcs (Mono C# compiler)
    local cs_files
    cs_files=$(ls "$dir"/*.cs 2>/dev/null | wc -l)
    if [ "$cs_files" -eq 1 ]; then
        local cs_file
        cs_file=$(ls "$dir"/*.cs 2>/dev/null | head -1)
        local out_name
        out_name=$(basename "$cs_file" .cs)
        echo "csharp-single|mcs $cs_file -target:exe -out:${out_name}.exe 2>&1 | tail -3"; return 0
    fi
    if [ -f "$dir/package.json" ]; then
        if jq -e '.scripts.build' "$dir/package.json" >/dev/null 2>&1; then
            echo "node|npm ci && npm run build"; return 0
        fi
    fi
    echo "none|"
}

# Decide whether to compile based on detection result + target dir
# Windows tools usually ship pre-compiled .exe, skip build even if Makefile present.
should_compile() {
    local target_dir="$1"
    local detected_lang="$2"

    [ "$detected_lang" = "none" ] && return 1
    # Allow C# single-file and dotnet builds on Linux even for windows/ tools
    [[ "$detected_lang" == "csharp-single" ]] && return 0
    [[ "$detected_lang" == "dotnet" ]] && return 0
    # Skip other windows tools (rust/go/cmake etc need Windows toolchain)
    [[ "$target_dir" == */windows/* ]] && return 1
    return 0
}

# Ensure the toolchain for a given language is installed (apt-installed once)
ensure_build_deps() {
    local lang="$1"
    case "$lang" in
        rust)
            command -v cargo >/dev/null && return 0
            print_status "Installing Rust toolchain..."
            apt_install_quiet cargo rustc
            ;;
        go)
            command -v go >/dev/null && return 0
            print_status "Installing Go toolchain..."
            apt_install_quiet golang
            ;;
        maven)
            command -v mvn >/dev/null && return 0
            print_status "Installing Maven..."
            apt_install_quiet maven
            ;;
        gradle)
            command -v gradle >/dev/null && return 0
            print_status "Installing Gradle..."
            apt_install_quiet gradle
            ;;
        cmake)
            command -v cmake >/dev/null && command -v gcc >/dev/null && return 0
            print_status "Installing CMake + build-essential..."
            apt_install_quiet cmake build-essential
            ;;
        autotools|make)
            command -v make >/dev/null && command -v gcc >/dev/null && return 0
            print_status "Installing build-essential..."
            apt_install_quiet build-essential
            ;;
        python|python-req)
            [ -f "/opt/pentest-venv/bin/pip" ] && return 0
            command -v pip3 >/dev/null && return 0
            print_status "Installing pip3..."
            apt_install_quiet python3-pip
            ;;
        dotnet|csharp-single)
            command -v mcs >/dev/null && return 0
            command -v dotnet >/dev/null && return 0
            print_status "Installing Mono C# compiler..."
            apt_install_quiet mono-mcs mono-devel
            ;;
        node)
            command -v npm >/dev/null && return 0
            print_status "Installing nodejs + npm..."
            apt_install_quiet nodejs npm
            ;;
    esac
}

apt_install_quiet() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >>"$PORTALGUN_LOG_DIR/apt.log" 2>&1 \
        || print_warning "Failed to install: $* (see $PORTALGUN_LOG_DIR/apt.log)"
}
