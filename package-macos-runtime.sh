#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_ROOT}/vendor/mpv/buildout"
OUT_DIR="${PROJECT_ROOT}/release"
PKG_NAME=""

usage() {
  cat <<'EOF'
Usage:
  bash ./package-macos-runtime.sh --pkg-name <name> [--build-dir <dir>] [--out-dir <dir>]

Build a self-contained macOS runtime package:
  - libmpv
  - all non-system dylib dependencies (recursive)
  - install names rewritten to @rpath/<lib>
  - @loader_path rpath added
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --pkg-name)
      PKG_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$PKG_NAME" ]; then
  echo "--pkg-name is required" >&2
  usage
  exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
  echo "Build directory not found: $BUILD_DIR" >&2
  exit 1
fi

LIB_DIR="$OUT_DIR/lib"
mkdir -p "$LIB_DIR"
rm -f "$LIB_DIR"/*

BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
BREW_LIB_DIR=""
if [ -n "$BREW_PREFIX" ]; then
  BREW_LIB_DIR="${BREW_PREFIX}/lib"
fi
VCPKG_INSTALLED_DIR="${VCPKG_INSTALLED_DIR:-$PROJECT_ROOT/vcpkg_installed}"
VCPKG_TARGET_TRIPLET="${VCPKG_TARGET_TRIPLET:-}"
if [ -z "$VCPKG_TARGET_TRIPLET" ]; then
  case "${MPV_TARGET_ARCH:-$(uname -m)}" in
    arm64)
      [ -d "$VCPKG_INSTALLED_DIR/arm64-osx-mp" ] && VCPKG_TARGET_TRIPLET="arm64-osx-mp" || VCPKG_TARGET_TRIPLET="arm64-osx"
      ;;
    x86_64)
      [ -d "$VCPKG_INSTALLED_DIR/x64-osx-mp" ] && VCPKG_TARGET_TRIPLET="x64-osx-mp" || VCPKG_TARGET_TRIPLET="x64-osx"
      ;;
  esac
fi
VCPKG_LIB_DIR=""
if [ -n "$VCPKG_TARGET_TRIPLET" ] && [ -d "$VCPKG_INSTALLED_DIR/$VCPKG_TARGET_TRIPLET/lib" ]; then
  VCPKG_LIB_DIR="$VCPKG_INSTALLED_DIR/$VCPKG_TARGET_TRIPLET/lib"
fi

TMP_DIR="$(mktemp -d)"
VISITED_FILE="${TMP_DIR}/visited.txt"
touch "$VISITED_FILE"
trap 'rm -rf "$TMP_DIR"' EXIT

already_visited() {
  grep -Fqx -- "$1" "$VISITED_FILE"
}

mark_visited() {
  printf '%s\n' "$1" >> "$VISITED_FILE"
}

is_system_dep() {
  case "$1" in
    /System/*|/usr/lib/*|/Library/Apple/*) return 0 ;;
    *) return 1 ;;
  esac
}

get_rpaths() {
  otool -l "$1" | awk '
    $1=="cmd" && $2=="LC_RPATH" {in_rpath=1; next}
    in_rpath && $1=="path" {print $2; in_rpath=0}
  '
}

resolve_dep() {
  local owner="$1"
  local dep="$2"
  local owner_dir candidate suffix rpath
  owner_dir="$(cd "$(dirname "$owner")" && pwd)"

  case "$dep" in
    /*)
      [ -e "$dep" ] && { echo "$dep"; return 0; }
      ;;
    @loader_path/*)
      candidate="${owner_dir}/${dep#@loader_path/}"
      [ -e "$candidate" ] && { echo "$candidate"; return 0; }
      ;;
    @executable_path/*)
      candidate="${owner_dir}/${dep#@executable_path/}"
      [ -e "$candidate" ] && { echo "$candidate"; return 0; }
      ;;
    @rpath/*)
      suffix="${dep#@rpath/}"
      while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        rpath="${rpath//@loader_path/$owner_dir}"
        rpath="${rpath//@executable_path/$owner_dir}"
        candidate="${rpath}/${suffix}"
        [ -e "$candidate" ] && { echo "$candidate"; return 0; }
      done < <(get_rpaths "$owner")
      ;;
  esac

  for search_dir in "$owner_dir" "$LIB_DIR" "$BUILD_DIR" "$VCPKG_LIB_DIR" "$BREW_LIB_DIR" /opt/homebrew/lib /usr/local/lib; do
    [ -n "$search_dir" ] || continue
    candidate="${search_dir}/$(basename "$dep")"
    [ -e "$candidate" ] && { echo "$candidate"; return 0; }
  done

  return 1
}

scan_and_copy_deps() {
  local owner="$1"
  local dep resolved dep_name target canonical

  [ -e "$owner" ] || return 0
  canonical="$(cd "$(dirname "$owner")" && pwd)/$(basename "$owner")"
  if already_visited "$canonical"; then
    return 0
  fi
  mark_visited "$canonical"

  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if is_system_dep "$dep"; then
      continue
    fi

    if ! resolved="$(resolve_dep "$owner" "$dep")"; then
      echo "Unresolved non-system dependency: $dep (owner: $owner)" >&2
      return 1
    fi

    dep_name="$(basename "$resolved")"
    target="${LIB_DIR}/${dep_name}"
    if [ ! -e "$target" ]; then
      cp -vL "$resolved" "$target"
      chmod u+w "$target" || true
    fi

    scan_and_copy_deps "$target"
  done < <(otool -L "$owner" | tail -n +2 | awk '{print $1}')
}

rewrite_install_names() {
  local file dep dep_name

  for file in "$LIB_DIR"/*; do
    [ -f "$file" ] || continue
    chmod u+w "$file" || true

    case "$file" in
      *.dylib|*.so)
        install_name_tool -id "@rpath/$(basename "$file")" "$file" || true
        ;;
    esac

    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      dep_name="$(basename "$dep")"
      if [ -e "$LIB_DIR/$dep_name" ]; then
        install_name_tool -change "$dep" "@rpath/$dep_name" "$file" || true
      fi
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')

    if ! (otool -l "$file" | grep -A2 'LC_RPATH' | grep -q '@loader_path'); then
      install_name_tool -add_rpath "@loader_path" "$file" || true
    fi
  done
}

verify_no_absolute_non_system_refs() {
  local file dep dep_name

  for file in "$LIB_DIR"/*; do
    [ -f "$file" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if is_system_dep "$dep"; then
        continue
      fi
      case "$dep" in
        @rpath/*|@loader_path/*|@executable_path/*)
          dep_name="$(basename "$dep")"
          if [ ! -e "$LIB_DIR/$dep_name" ]; then
            echo "Packaged dependency missing: $dep (owner: $file)" >&2
            return 1
          fi
          ;;
        /*)
          echo "Absolute non-system dependency remains: $dep (owner: $file)" >&2
          return 1
          ;;
      esac
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
  done
}

copy_root_mpv_libs() {
  local found=0
  local src
  shopt -s nullglob
  for src in "$BUILD_DIR"/libmpv*.dylib; do
    if [ -f "$src" ] || [ -L "$src" ]; then
      cp -vP "$src" "$LIB_DIR/"
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "No libmpv*.dylib found in $BUILD_DIR" >&2
    exit 1
  fi
}

echo "Preparing runtime bundle from: $BUILD_DIR"
copy_root_mpv_libs

for file in "$LIB_DIR"/libmpv*.dylib; do
  [ -e "$file" ] || continue
  scan_and_copy_deps "$file"
done

rewrite_install_names
verify_no_absolute_non_system_refs

tar -czf "${PKG_NAME}.tar.gz" -C "$OUT_DIR" .
shasum -a 256 "${PKG_NAME}.tar.gz" > "${PKG_NAME}.tar.gz.sha256"

echo "Created package: ${PKG_NAME}.tar.gz"
echo "Created checksum: ${PKG_NAME}.tar.gz.sha256"
