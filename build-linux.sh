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

for tool in meson ninja pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not found in PATH" >&2
        exit 1
    fi
done

BUILD_ARCH="$(uname -m)"
case "$BUILD_ARCH" in
    x86_64|aarch64|arm64) ;;
    *)
        echo "Warning: unverified Linux arch: $BUILD_ARCH" >&2
        ;;
esac

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$PROJECT_ROOT/.cache}"
mkdir -p "$XDG_CACHE_HOME"

cd "$MPV_DIR"

MESON_ARGS=(
    --buildtype=release
    -Dlibmpv=true
    -Dcplayer=false
    -Dlua=enabled
    -Dvulkan=enabled
    -Dwayland=enabled
    -Dx11=enabled
    -Dpulse=enabled
)

if [ ! -d "$BUILD_DIR" ]; then
    echo "Configuring Meson..."
    meson setup buildout "${MESON_ARGS[@]}"
else
    echo "Reconfiguring Meson (wipe old options)..."
    meson setup buildout --reconfigure "${MESON_ARGS[@]}"
fi

echo "Building..."
meson compile -C buildout

SO_COUNT="$(ls -1 "$BUILD_DIR"/libmpv*.so* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$SO_COUNT" = "0" ]; then
    echo "Build finished but no libmpv*.so* found in $BUILD_DIR" >&2
    exit 1
fi

echo "Build output ready in: $BUILD_DIR"
