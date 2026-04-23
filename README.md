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
- `x64-osx-mp` (deployment target `13.0`)
- `arm64-osx-mp-static` (same as `arm64-osx-mp`, but static library linkage)
- `x64-osx-mp-static` (same as `x64-osx-mp`, but static library linkage)

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

Dependencies are installed in two phases:
- Step 1: ports listed in `STATIC_PORTS=(...)` inside `install-vcpkg-deps.sh` using `${VCPKG_TARGET_TRIPLET}-static`
- Step 2: ports listed in `DYNAMIC_PORTS=(...)` using `${VCPKG_TARGET_TRIPLET}`

To change static vs dynamic grouping, edit those two arrays directly in `install-vcpkg-deps.sh`.

## Verify Static Library Output

Example: verify `luajit` was installed as static library.

```bash
# 1) Confirm static archive exists for the static triplet
ls -lh ./vcpkg_installed/$(uname -m | sed 's/arm64/arm64-osx-mp-static/;s/x86_64/x64-osx-mp-static/')/lib/libluajit*.a

# 2) Confirm no dylib is present for that triplet (expected for static linkage)
find ./vcpkg_installed/$(uname -m | sed 's/arm64/arm64-osx-mp-static/;s/x86_64/x64-osx-mp-static/') -name 'libluajit*.dylib'
```

If step 1 prints a `libluajit*.a` path and step 2 prints nothing, `luajit` is installed as static.

You can also check install metadata:

```bash
rg -n "luajit:.*-static" ./vcpkg_installed/vcpkg/status
```

## Switch A Port From Dynamic To Static

When dynamic and static triplets both exist, they are installed side-by-side.  
You can either keep both, or remove the dynamic one before reinstalling static.

Remove dynamic package(s) for a specific triplet:

```bash
# Example: remove luajit dynamic package for arm64 triplet
./vcpkg/vcpkg remove luajit:arm64-osx-mp --overlay-triplets=./vcpkg-triplets --x-install-root=./vcpkg_installed

# Example: remove multiple dynamic packages
./vcpkg/vcpkg remove luajit:arm64-osx-mp mujs:arm64-osx-mp --overlay-triplets=./vcpkg-triplets --x-install-root=./vcpkg_installed
```

Then reinstall with your current script-defined grouping:

```bash
VCPKG_TARGET_TRIPLET=arm64-osx-mp bash ./install-vcpkg-deps.sh
```

If you want a full clean reinstall for one triplet:

```bash
rm -rf ./vcpkg_installed/arm64-osx-mp
VCPKG_TARGET_TRIPLET=arm64-osx-mp bash ./install-vcpkg-deps.sh
```

## Build mpv/libmpv

Download patched mpv source (`vendor/mpv`):

```bash
bash ./download.sh
```

Build with defaults for the host arch:

```bash
bash ./build-macos.sh
```

`build-macos.sh` now builds MoltenVK before Meson configure/compile and copies artifacts to:
- `vendor/MoltenVK/Build/Release/libMoltenVK.dylib`
- `vendor/MoltenVK/Package/Release/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json`

Set `AUTO_BUILD_MOLTENVK=0` to skip this step.

Build a specific mpv version:

```bash
MPV_VERSION=0.41.1 bash ./download.sh
bash ./build-macos.sh
```

ffmpeg is built via overlay port `vcpkg-ports/ffmpeg` with fixed configure flags:
- `--disable-programs`
- `--enable-small`
- `--enable-openssl`
- `--disable-mbedtls`

Cross-build `x86_64` on Apple Silicon:

```bash
VCPKG_TARGET_TRIPLET=x64-osx-mp bash ./install-vcpkg-deps.sh
MPV_TARGET_ARCH=x86_64 \
VCPKG_TARGET_TRIPLET=x64-osx-mp \
MACOSX_DEPLOYMENT_TARGET=13.0 \
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

`package-macos-runtime.sh` uses `MPV_TARGET_ARCH` (`arm64` or `x86_64`) to select target-arch artifacts.
If omitted, it falls back to `uname -m`.

```bash
MPV_TARGET_ARCH=arm64  bash ./package-macos-runtime.sh --pkg-name libmpv-local-macos-arm64
MPV_TARGET_ARCH=x86_64 bash ./package-macos-runtime.sh --pkg-name libmpv-local-macos-x64
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
- `MOLTENVK_REF`: MoltenVK git ref for `build-macos.sh` (default `v1.4.0`)
- `MOLTENVK_REPO_DIR`: MoltenVK source dir (default `./vendor/MoltenVK`)
- `MOLTENVK_OUTPUT_DIR`: MoltenVK output dir (default `./vendor/MoltenVK/Build/Release`)
- `MOLTENVK_LIB_PATH`: MoltenVK dylib path (default `./vendor/MoltenVK/Build/Release/libMoltenVK.dylib`)
- `MOLTENVK_ICD_PATH`: MoltenVK ICD json path (default `./vendor/MoltenVK/Package/Release/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json`)
- `MOLTENVK_DERIVED_DATA_DIR`: Xcode DerivedData path for MoltenVK build (default `./vendor/MoltenVK/Build/DerivedData`)
- `MACOSX_DEPLOYMENT_TARGET`: macOS minimum target passed to compilers (default: `14.0` for `arm64`, `13.0` for `x86_64`)

## CI Notes

GitHub Actions workflow (`.github/workflows/ci.yml`) builds both:
- `arm64` on `macos-15` with triplet `arm64-osx-mp`
- `x86_64` on `macos-15` with triplet `x64-osx-mp`

Tag naming for release assets:
- `vX.Y.Z` -> revision `r0`
- `vX.Y.Z-rN` -> revision `rN`
