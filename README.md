# Soia mpv vcpkg Build

This repository builds `libmpv` for Soia Media Player on macOS, with dependencies provided by `vcpkg`.

The build flow is:
1. Install dependencies into `vcpkg_installed/<triplet>`
2. Build `vendor/mpv/buildout/libmpv*.dylib` with Meson
3. Package a self-contained runtime tarball

## What Gets Produced

Each package includes:
- `libmpv*.dylib`
- all recursively discovered non-system dylib dependencies
- rewritten install names (`@rpath/<lib>`) and `@loader_path` rpath
- `sha256` checksum file

The runtime package is intended to run on target machines without Homebrew.

## Prerequisites

Install host tools:

```bash
brew install pkgconf autoconf autoconf-archive automake libtool
python3 -m pip install --upgrade meson ninja
```

Bootstrap `vcpkg`:

```bash
git clone --depth 1 https://github.com/microsoft/vcpkg.git ./vcpkg
./vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

## Triplets And Deployment Targets

Custom overlay triplets are in `vcpkg-triplets/`:
- `arm64-osx-mp` (deployment target `14.0`)
- `x64-osx-mp` (deployment target `14.0`)

Important:
- Keep `MACOSX_DEPLOYMENT_TARGET` in `build-macos.sh` aligned with the triplet deployment target for the same arch.
- If they differ, your final package may contain dylibs that require a newer macOS than `libmpv` itself.

## Install vcpkg Dependencies

By default, `install-vcpkg-deps.sh` auto-selects:
- Apple Silicon host: `arm64-osx-mp`
- Intel host: `x64-osx-mp`

```bash
bash ./install-vcpkg-deps.sh
```

Specify triplet explicitly when needed:

```bash
VCPKG_TARGET_TRIPLET=arm64-osx-mp bash ./install-vcpkg-deps.sh
VCPKG_TARGET_TRIPLET=x64-osx-mp   bash ./install-vcpkg-deps.sh
```

The script uses:
- overlay ports: `vcpkg-ports/`
- overlay triplets: `vcpkg-triplets/`
- install root: `./vcpkg_installed`

Default dependency set now includes `libsmb2` (SMB2/SMB3 client support).

## Build mpv/libmpv

Download patched mpv source (`vendor/mpv`):

```bash
bash ./download.sh
```

Build with defaults for the host arch:

```bash
bash ./build-macos.sh
```

Build a specific mpv version:

```bash
MPV_VERSION=0.41.1 bash ./download.sh
bash ./build-macos.sh
```

Cross-build `x86_64` on Apple Silicon:

```bash
VCPKG_TARGET_TRIPLET=x64-osx-mp bash ./install-vcpkg-deps.sh
MPV_TARGET_ARCH=x86_64 \
VCPKG_TARGET_TRIPLET=x64-osx-mp \
MACOSX_DEPLOYMENT_TARGET=14.0 \
bash ./build-macos.sh
```

Native Apple Silicon build (matching `arm64-osx-mp` deployment target):

```bash
VCPKG_TARGET_TRIPLET=arm64-osx-mp bash ./install-vcpkg-deps.sh
MPV_TARGET_ARCH=arm64 \
VCPKG_TARGET_TRIPLET=arm64-osx-mp \
MACOSX_DEPLOYMENT_TARGET=14.0 \
bash ./build-macos.sh
```

## Package Runtime

Create runtime package:

```bash
bash ./package-macos-runtime.sh --pkg-name libmpv-local-macos
```

Custom output dir/build dir:

```bash
bash ./package-macos-runtime.sh \
  --build-dir ./vendor/mpv/buildout \
  --out-dir ./release \
  --pkg-name libmpv-0.41.0-r0-macos-arm64
```

Outputs:
- `./<pkg-name>.tar.gz`
- `./<pkg-name>.tar.gz.sha256`

## Common Environment Variables

- `MPV_VERSION`: mpv version for `download.sh` (default `0.41.0`)
- `MPV_TARGET_ARCH`: `arm64` or `x86_64`
- `VCPKG_TARGET_TRIPLET`: e.g. `arm64-osx-mp`, `x64-osx-mp`
- `VCPKG_ROOT`: vcpkg checkout path (default `./vcpkg`)
- `VCPKG_INSTALLED_DIR`: install root (default `./vcpkg_installed`)
- `MACOSX_DEPLOYMENT_TARGET`: macOS minimum target passed to compilers

## CI Notes

GitHub Actions workflow (`.github/workflows/ci.yml`) builds both:
- `arm64` on `macos-15` with triplet `arm64-osx-mp`
- `x86_64` on `macos-15` with triplet `x64-osx-mp`

Tag naming for release assets:
- `vX.Y.Z` -> revision `r0`
- `vX.Y.Z-rN` -> revision `rN`
