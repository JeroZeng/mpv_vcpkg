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
    command -v aclocal >/dev/null 2>&1 || missing_tools+=("automake")
    if command -v libtoolize >/dev/null 2>&1; then
        export LIBTOOLIZE="$(command -v libtoolize)"
    elif command -v glibtoolize >/dev/null 2>&1; then
        export LIBTOOLIZE="$(command -v glibtoolize)"
        TOOL_SHIM_DIR="${PROJECT_ROOT}/.cache/tool-shims"
        mkdir -p "$TOOL_SHIM_DIR"
        ln -sf "$LIBTOOLIZE" "$TOOL_SHIM_DIR/libtoolize"
        export PATH="$TOOL_SHIM_DIR:$PATH"
        export LIBTOOLIZE="$TOOL_SHIM_DIR/libtoolize"
    else
        missing_tools+=("libtool")
    fi

    if [ "${#missing_tools[@]}" -gt 0 ]; then
        echo "Missing required system build tools: ${missing_tools[*]}" >&2
        echo "Install them first: brew install autoconf autoconf-archive automake libtool" >&2
        exit 1
    fi

    echo "Using LIBTOOLIZE=$LIBTOOLIZE"

    # Match vcpkg's aclocal/autoconf-archive preflight behavior early so
    # we fail fast with a clear hint instead of failing during a port build.
    ACLOCAL_CHECK_DIR="${PROJECT_ROOT}/.cache/aclocal-check"
    rm -rf "$ACLOCAL_CHECK_DIR"
    mkdir -p "$ACLOCAL_CHECK_DIR"
    cat > "$ACLOCAL_CHECK_DIR/configure.ac" <<'EOF'
AC_INIT([check-autoconf], [1.0])
AM_INIT_AUTOMAKE
LT_INIT
AX_PTHREAD
EOF

    ACLOCAL_ERR_LOG="$ACLOCAL_CHECK_DIR/aclocal.err.log"
    if ! (cd "$ACLOCAL_CHECK_DIR" && aclocal --dry-run > /dev/null 2>"$ACLOCAL_ERR_LOG"); then
        cat "$ACLOCAL_ERR_LOG" >&2 || true
        echo "aclocal preflight failed. Install required tools: brew install autoconf autoconf-archive automake libtool" >&2
        exit 1
    fi
    if grep -Eiq "autoconf-archive.*missing" "$ACLOCAL_ERR_LOG"; then
        cat "$ACLOCAL_ERR_LOG" >&2 || true
        echo "autoconf-archive is required by vcpkg ports (for AX_* macros)." >&2
        echo "Install it with: brew install autoconf-archive" >&2
        exit 1
    fi
fi

STATIC_PORTS=(
    luajit
    mujs
)

DYNAMIC_PORTS=(
    libarchive
    freetype
    fribidi
    harfbuzz
    dav1d
    lcms
    libass
    ffmpeg
    uchardet
    vulkan
    libbluray
    libdvdnav
    libsmb2
    opus
    rubberband
    libjpeg-turbo
    libiconv
    shaderc
    libplacebo
)

# Explicit ffmpeg feature set to avoid "minimal" defaults.
# Keep this aligned with DYNAMIC_PORTS dependencies and project needs.
FFMPEG_FEATURES=(
    ass
    bzip2
    dav1d
    drawtext
    freetype
    fribidi
    iconv
    lzma
    opus
    openssl
    rubberband
    vulkan
    zlib
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

STATIC_TRIPLET="${VCPKG_TARGET_TRIPLET}-static"
STATIC_SPECS=()
DYNAMIC_SPECS=()

if [ "${#STATIC_PORTS[@]}" -gt 0 ] && [ ! -f "$OVERLAY_TRIPLETS_DIR/${STATIC_TRIPLET}.cmake" ]; then
    echo "Missing static triplet file: $OVERLAY_TRIPLETS_DIR/${STATIC_TRIPLET}.cmake" >&2
    echo "Create the static triplet first or adjust VCPKG_TARGET_TRIPLET." >&2
    exit 1
fi

for port in "${STATIC_PORTS[@]}"; do
    STATIC_SPECS+=("${port}:${STATIC_TRIPLET}")
done
for port in "${DYNAMIC_PORTS[@]}"; do
    if [ "$port" = "ffmpeg" ]; then
        if [ "${#FFMPEG_FEATURES[@]}" -gt 0 ]; then
            ffmpeg_features_csv="$(IFS=,; echo "${FFMPEG_FEATURES[*]}")"
            DYNAMIC_SPECS+=("ffmpeg[${ffmpeg_features_csv}]:${VCPKG_TARGET_TRIPLET}")
        else
            DYNAMIC_SPECS+=("ffmpeg:${VCPKG_TARGET_TRIPLET}")
        fi
    else
        DYNAMIC_SPECS+=("${port}:${VCPKG_TARGET_TRIPLET}")
    fi
done

if [ "${#STATIC_SPECS[@]}" -gt 0 ]; then
    echo "Step 1/2: installing static ports with triplet: $STATIC_TRIPLET"
    echo "Static ports: ${STATIC_PORTS[*]}"
    "$VCPKG_ROOT/vcpkg" install \
        --recurse \
        --overlay-ports="$OVERLAY_PORTS_DIR" \
        --overlay-triplets="$OVERLAY_TRIPLETS_DIR" \
        --x-install-root="$VCPKG_INSTALLED_DIR" \
        "${STATIC_SPECS[@]}"
fi

if [ "${#DYNAMIC_SPECS[@]}" -gt 0 ]; then
    echo "Step 2/2: installing dynamic ports with triplet: $VCPKG_TARGET_TRIPLET"
    if [ "${#STATIC_SPECS[@]}" -gt 0 ]; then
        echo "Dynamic ports: ${DYNAMIC_PORTS[*]}"
    fi
    if [ "${#FFMPEG_FEATURES[@]}" -gt 0 ]; then
        echo "ffmpeg features: ${FFMPEG_FEATURES[*]}"
    fi
    "$VCPKG_ROOT/vcpkg" install \
        --recurse \
        --overlay-ports="$OVERLAY_PORTS_DIR" \
        --overlay-triplets="$OVERLAY_TRIPLETS_DIR" \
        --x-install-root="$VCPKG_INSTALLED_DIR" \
        "${DYNAMIC_SPECS[@]}"
fi

if [ "${#STATIC_SPECS[@]}" -eq 0 ] && [ "${#DYNAMIC_SPECS[@]}" -eq 0 ]; then
    echo "No ports to install." >&2
    exit 1
fi
