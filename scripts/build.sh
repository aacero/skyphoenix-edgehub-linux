#!/usr/bin/env bash
# Build script for Xeneon Edge Linux Hub
# Usage: ./scripts/build.sh [debug|release]

set -euo pipefail

BUILD_TYPE="${1:-debug}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"

case "$BUILD_TYPE" in
    debug)   CMAKE_BUILD_TYPE="Debug" ;;
    release) CMAKE_BUILD_TYPE="Release" ;;
    *) echo "Unknown build type: $BUILD_TYPE"; exit 1 ;;
esac

echo "==> Xeneon Edge Linux Hub Build"
echo "    Build type: ${CMAKE_BUILD_TYPE}"
echo "    Project:    ${PROJECT_DIR}"

# Check prerequisites
echo "==> Checking prerequisites..."

if ! command -v rustc &> /dev/null; then
    echo "ERROR: Rust is not installed."
    echo "  Install with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
    echo "  Then restart your shell or run: source ~/.cargo/env.fish (or .env for bash)"
    exit 1
fi
echo "    Rust: $(rustc --version)"

if ! command -v cmake &> /dev/null; then
    echo "ERROR: CMake is not installed."
    echo "  Arch/CachyOS: sudo pacman -S cmake"
    echo "  Ubuntu/Debian: sudo apt-get install cmake"
    echo "  Fedora: sudo dnf install cmake"
    exit 1
fi
echo "    CMake: $(cmake --version | head -1)"

if ! command -v g++ &> /dev/null; then
    echo "ERROR: C++ compiler (g++) not found."
    echo "  Arch/CachyOS: sudo pacman -S gcc"
    echo "  Ubuntu/Debian: sudo apt-get install g++"
    exit 1
fi
echo "    C++: $(g++ --version | head -1)"

# Check Qt6
if ! pkg-config --exists Qt6Core 2>/dev/null; then
    echo "ERROR: Qt6 development packages not found."
    echo "  Arch/CachyOS: sudo pacman -S qt6-base qt6-declarative qt6-svg qt6-wayland"
    echo "  Ubuntu 26.04: sudo apt-get install qt6-base-dev qt6-declarative-dev qt6-svg-dev"
    echo "  Fedora 43: sudo dnf install qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtsvg-devel"
    exit 1
fi
echo "    Qt6: $(pkg-config --modversion Qt6Core)"

# Step 1: Build Rust core library
echo ""
echo "==> Building Rust core library..."
cd "${PROJECT_DIR}/core"
if [ "$BUILD_TYPE" = "release" ]; then
    cargo build --release --locked
else
    cargo build --locked
fi
echo "    Done."

# Step 2: Configure with CMake
echo ""
echo "==> Configuring CMake..."
cd "${PROJECT_DIR}"
cmake -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DXENEON_QA_HOOKS=ON \
    -G "Unix Makefiles"
# Dev builds enable the QA automation hooks (screenshot capture / auto-open) so
# the test + hardware-E2E suites and marketing-capture flows work. Production
# packaging (packaging/aur/PKGBUILD, CPack) leaves them OFF.

# Step 3: Build
echo ""
echo "==> Building..."
# Parallel Qt/LTO compilation is the largest steady-state memory consumer in the
# repo: two 25 MB generated qrc_wallpapers.cpp translation units plus a full Qt
# link. `-j$(nproc)` scales peak RAM with core count, which on a many-core box
# is a classic local OOM. Cap the job count and let make back off under load.
# Override with BUILD_JOBS=N.
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
[ "$BUILD_JOBS" -gt 16 ] && BUILD_JOBS=16
cmake --build "${BUILD_DIR}" -- -j"${BUILD_JOBS}" -l"$(nproc)"

echo ""
echo "==> Build complete!"
echo "    Binary: ${BUILD_DIR}/xeneon-edge-hub"
echo "    Run with: ${BUILD_DIR}/xeneon-edge-hub"
