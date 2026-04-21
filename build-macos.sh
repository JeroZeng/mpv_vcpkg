#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$PROJECT_ROOT/vendor"
MPV_DIR="$VENDOR_DIR/mpv"
BUILD_DIR="$MPV_DIR/buildout"

if [ ! -d "$MPV_DIR" ]; then
    echo "Missing mpv source: $MPV_DIR"
    echo "Run: ./download.sh"
    exit 1
fi

HOST_ARCH="$(uname -m)"
MPV_TARGET_ARCH="${MPV_TARGET_ARCH:-$HOST_ARCH}"
case "$MPV_TARGET_ARCH" in
    arm64|x86_64) ;;
    *)
        echo "Unsupported MPV_TARGET_ARCH: $MPV_TARGET_ARCH" >&2
        exit 1
        ;;
esac

VCPKG_ROOT="${VCPKG_ROOT:-$PROJECT_ROOT/vcpkg}"
VCPKG_INSTALLED_DIR="${VCPKG_INSTALLED_DIR:-$PROJECT_ROOT/vcpkg_installed}"
if [ -z "${VCPKG_TARGET_TRIPLET:-}" ]; then
    case "$MPV_TARGET_ARCH" in
        arm64)
            if [ -d "$VCPKG_INSTALLED_DIR/arm64-osx-mp" ]; then
                VCPKG_TARGET_TRIPLET="arm64-osx-mp"
            else
                VCPKG_TARGET_TRIPLET="arm64-osx"
            fi
            ;;
        x86_64)
            if [ -d "$VCPKG_INSTALLED_DIR/x64-osx-mp" ]; then
                VCPKG_TARGET_TRIPLET="x64-osx-mp"
            else
                VCPKG_TARGET_TRIPLET="x64-osx"
            fi
            ;;
    esac
fi
VCPKG_PREFIX="$VCPKG_INSTALLED_DIR/$VCPKG_TARGET_TRIPLET"
if [ ! -d "$VCPKG_PREFIX" ]; then
    echo "Missing vcpkg install root for triplet: $VCPKG_TARGET_TRIPLET" >&2
    echo "Expected path: $VCPKG_PREFIX" >&2
    exit 1
fi

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
MIN_OS_FLAG="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
ARCH_FLAG="-arch ${MPV_TARGET_ARCH}"
SWIFT_TARGET_TRIPLE="${MPV_TARGET_ARCH}-apple-macos${MACOSX_DEPLOYMENT_TARGET}"
SWIFT_FLAGS="-target ${SWIFT_TARGET_TRIPLE}"
PKG_CONFIG_DIRS="$VCPKG_PREFIX/lib/pkgconfig:$VCPKG_PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_DIRS${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_DIRS"
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config is required but not found in PATH" >&2
    exit 1
fi
export CFLAGS="$ARCH_FLAG $MIN_OS_FLAG ${CFLAGS:-}"
export CXXFLAGS="$ARCH_FLAG $MIN_OS_FLAG ${CXXFLAGS:-}"
export OBJCFLAGS="$ARCH_FLAG $MIN_OS_FLAG ${OBJCFLAGS:-}"
export OBJCXXFLAGS="$ARCH_FLAG $MIN_OS_FLAG ${OBJCXXFLAGS:-}"
export LDFLAGS="-L$VCPKG_PREFIX/lib $ARCH_FLAG $MIN_OS_FLAG ${LDFLAGS:-}"
export CPPFLAGS="-I$VCPKG_PREFIX/include ${CPPFLAGS:-}"
export XDG_CACHE_HOME="$PROJECT_ROOT/.cache"
export CLANG_MODULE_CACHE_PATH="$XDG_CACHE_HOME/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$XDG_CACHE_HOME/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

cd "$MPV_DIR"
echo "Building for arch=$MPV_TARGET_ARCH on host=$HOST_ARCH"
echo "Using vcpkg triplet=$VCPKG_TARGET_TRIPLET"
echo "Using vcpkg root=$VCPKG_ROOT"
echo "Using PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
echo "Building with MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
echo "Building with Swift target=$SWIFT_TARGET_TRIPLE"

MESON_ARGS=(
    --buildtype=release
    -Dlibmpv=true
    -Dcplayer=false
    -Dmacos-media-player=enabled
    -Dcoreaudio=enabled
    -Dvulkan=enabled
    -Dlua=enabled
    -Dswift-build=enabled
    "-Dswift-flags=${SWIFT_FLAGS}"
)

MESON_CROSS_ARGS=()
if [ "$MPV_TARGET_ARCH" != "$HOST_ARCH" ]; then
    case "$MPV_TARGET_ARCH" in
        arm64) MESON_CPU_FAMILY="aarch64" ;;
        x86_64) MESON_CPU_FAMILY="x86_64" ;;
    esac
    CROSS_FILE="$XDG_CACHE_HOME/meson-cross-${MPV_TARGET_ARCH}.ini"
    cat > "$CROSS_FILE" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
objcpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
swift = 'swiftc'

[host_machine]
system = 'darwin'
cpu_family = '${MESON_CPU_FAMILY}'
cpu = '${MPV_TARGET_ARCH}'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
    MESON_CROSS_ARGS+=(--cross-file "$CROSS_FILE")
fi

if [ ! -d "$BUILD_DIR" ]; then
    echo "Configuring Meson..."
    if [ "${#MESON_CROSS_ARGS[@]}" -gt 0 ]; then
        meson setup buildout "${MESON_ARGS[@]}" "${MESON_CROSS_ARGS[@]}"
    else
        meson setup buildout "${MESON_ARGS[@]}"
    fi
else
    echo "Reconfiguring Meson (wipe old options)..."
    if [ "${#MESON_CROSS_ARGS[@]}" -gt 0 ]; then
        meson setup buildout --wipe "${MESON_ARGS[@]}" "${MESON_CROSS_ARGS[@]}"
    else
        meson setup buildout --wipe "${MESON_ARGS[@]}"
    fi
fi

echo "Building..."
meson compile -C buildout

LIBMPV_DYLIB="$BUILD_DIR/libmpv.2.dylib"
if [[ "$MACOSX_DEPLOYMENT_TARGET" == 13* ]] && [ -f "$LIBMPV_DYLIB" ] &&
    nm -u "$LIBMPV_DYLIB" | grep -q '_\$ss20__StaticArrayStorageCN'; then
    echo "Detected Swift runtime symbol unsupported on macOS 13: _\\$ss20__StaticArrayStorageCN" >&2
    echo "Check swift target/deployment settings before packaging." >&2
    exit 1
fi
