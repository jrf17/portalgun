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
        echo "python|pip install --break-system-packages --user ."; return 0
    fi
    if ls "$dir"/*.csproj >/dev/null 2>&1 || ls "$dir"/*.sln >/dev/null 2>&1; then
        echo "dotnet|dotnet build -c Release"; return 0
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
        python)
            command -v pip3 >/dev/null && return 0
            print_status "Installing pip3..."
            apt_install_quiet python3-pip
            ;;
        dotnet)
            command -v dotnet >/dev/null && return 0
            print_status "Installing .NET SDK..."
            apt_install_quiet dotnet-sdk-8.0
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
