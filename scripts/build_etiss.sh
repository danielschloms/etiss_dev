#!/usr/bin/env bash
#
# build_etiss.sh - Configure, build and install ETISS quickly.
#
# Usage:
#   scripts/build_etiss.sh [options]
#
# Options:
#   -b, --build-type <type>   CMake build type (Release|Debug) [default: Release]
#   -j, --jobs <n>            Number of parallel jobs [default: $(nproc)]
#   -p, --prefix <dir>        Install prefix [default: <etiss>/build/installed]
#   --no-install              Build only, do not install
#   --configure-only          Only run the CMake configure step
#   --clean                   Re-create the build directory from scratch
#   -h, --help                Show this help

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ETISS_DIR="$PROJECT_ROOT/etiss"

BUILD_TYPE="Release"
JOBS="$(nproc)"
PREFIX=""
DO_INSTALL=1
CONFIGURE_ONLY=0
CLEAN=0

usage() {
    cat <<'EOF'
build_etiss.sh - Configure, build and install ETISS quickly.

Usage:
  scripts/build_etiss.sh [options]

Options:
  -b, --build-type <type>   CMake build type (Release|Debug) [default: Release]
  -j, --jobs <n>            Number of parallel jobs [default: $(nproc)]
  -p, --prefix <dir>        Install prefix [default: <etiss>/build/installed]
  --no-install              Build only, do not install
  --configure-only          Only run the CMake configure step
  --clean                   Re-create the build directory from scratch
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build-type) BUILD_TYPE="$2"; shift 2 ;;
        -j|--jobs)       JOBS="$2";       shift 2 ;;
        -p|--prefix)     PREFIX="$2";     shift 2 ;;
        --no-install)    DO_INSTALL=0;    shift ;;
        --configure-only) CONFIGURE_ONLY=1; shift ;;
        --clean)         CLEAN=1;         shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Resolve build dir and install prefix relative to the ETISS repo.
BUILD_DIR="$ETISS_DIR/build"
if [[ -z "$PREFIX" ]]; then
    PREFIX="$BUILD_DIR/installed"
fi

cd "$ETISS_DIR"

# Detect ccache to speed up rebuilds.
CCACHE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
    CCACHE_ARGS=(-D CMAKE_C_COMPILER_LAUNCHER=ccache -D CMAKE_CXX_COMPILER_LAUNCHER=ccache)
else
    echo "ccache not found, continuing without it (install it for faster rebuilds)." >&2
fi

if [[ "$CLEAN" -eq 1 ]]; then
    echo "Cleaning build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

echo "=== Configuring ETISS ($BUILD_TYPE) ==="
echo "  build dir : $BUILD_DIR"
echo "  install   : $PREFIX"
cmake -S "$ETISS_DIR" -B "$BUILD_DIR" \
    -D CMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -D CMAKE_INSTALL_PREFIX="$PREFIX" \
    "${CCACHE_ARGS[@]}"

if [[ "$CONFIGURE_ONLY" -eq 1 ]]; then
    echo "=== Configure only; skipping build ==="
    exit 0
fi

echo "=== Building ETISS (using $JOBS jobs) ==="
cmake --build "$BUILD_DIR" --parallel "$JOBS"

if [[ "$DO_INSTALL" -eq 1 ]]; then
    echo "=== Installing ETISS to $PREFIX ==="
    cmake --build "$BUILD_DIR" --target install
fi

echo "=== Done ==="
echo "ETISS build artifacts : $BUILD_DIR"
echo "ETISS install prefix  : $PREFIX"
