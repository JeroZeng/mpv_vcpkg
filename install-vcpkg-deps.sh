#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VCPKG_ROOT="${VCPKG_ROOT:-$PROJECT_ROOT/vcpkg}"
VCPKG_INSTALLED_DIR="${VCPKG_INSTALLED_DIR:-$PROJECT_ROOT/vcpkg_installed}"
VCPKG_TARGET_TRIPLET="${VCPKG_TARGET_TRIPLET:-}"
OVERLAY_TRIPLETS_DIR="$PROJECT_ROOT/vcpkg-triplets"
OVERLAY_PORTS_DIR="$PROJECT_ROOT/vcpkg-ports"

if [ -z "$VCPKG_TARGET_TRIPLET" ]; then
    case "$(uname -m)" in
        arm64)
            VCPKG_TARGET_TRIPLET="arm64-osx-mp"
            ;;
        x86_64)
            VCPKG_TARGET_TRIPLET="x64-osx-mp"
            ;;
        *)
            echo "Unsupported host architecture for default triplet: $(uname -m)" >&2
            exit 1
            ;;
    esac
fi

if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
    echo "Missing vcpkg executable at $VCPKG_ROOT/vcpkg" >&2
    echo "Run vcpkg bootstrap first." >&2
    exit 1
fi

if [ "$(uname -s)" = "Darwin" ]; then
    missing_tools=()
    command -v autoconf >/dev/null 2>&1 || missing_tools+=("autoconf")
    command -v automake >/dev/null 2>&1 || missing_tools+=("automake")
    if ! command -v libtoolize >/dev/null 2>&1 && ! command -v glibtoolize >/dev/null 2>&1; then
        missing_tools+=("libtool")
    fi

    if [ "${#missing_tools[@]}" -gt 0 ]; then
        echo "Missing required system build tools: ${missing_tools[*]}" >&2
        echo "Install them first: brew install autoconf autoconf-archive automake libtool" >&2
        exit 1
    fi
fi

PORTS=(
    freetype
    fribidi
    lcms
    libass
    ffmpeg
    libplacebo
    luajit
    mujs
    uchardet
    vulkan
    libarchive
    libbluray
    libdvdnav
    rubberband
    libjpeg-turbo
)

UNAVAILABLE_OPTIONAL_PORTS=(
    libcaca
    libcdio
    zimg
)

for port in "${UNAVAILABLE_OPTIONAL_PORTS[@]}"; do
    if [ ! -d "$VCPKG_ROOT/ports/$port" ]; then
        echo "Skipping unavailable optional port in current vcpkg baseline: $port"
    fi
done

VCPKG_SPECS=()
for port in "${PORTS[@]}"; do
    VCPKG_SPECS+=("${port}:${VCPKG_TARGET_TRIPLET}")
done

echo "Installing vcpkg dependencies for triplet: $VCPKG_TARGET_TRIPLET"
"$VCPKG_ROOT/vcpkg" install \
    --clean-after-build \
    --overlay-ports="$OVERLAY_PORTS_DIR" \
    --overlay-triplets="$OVERLAY_TRIPLETS_DIR" \
    --x-install-root="$VCPKG_INSTALLED_DIR" \
    "${VCPKG_SPECS[@]}"
