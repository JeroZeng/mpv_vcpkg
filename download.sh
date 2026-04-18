#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$PROJECT_ROOT/vendor"
MPV_DIR="$VENDOR_DIR/mpv"
MPV_VERSION="${MPV_VERSION:-0.41.0}"
VERSION_FILE="$MPV_DIR/.mpv-version"
TARBALL="$VENDOR_DIR/mpv-v${MPV_VERSION}.tar.gz"
SOURCE_URL="https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"

mkdir -p "$VENDOR_DIR"

if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$MPV_VERSION" ]; then
    echo "mpv v${MPV_VERSION} already exists at $MPV_DIR"
    exit 0
fi

apply_patch() {
    patch -d vendor/mpv -p1 -N <<'PATCH'
diff --git a/player/scripting.c b/player/scripting.c
index cb3257e1b4..de23b7e893 100644
--- a/player/scripting.c
+++ b/player/scripting.c
@@ -38,6 +38,7 @@
 #include "mpv/client.h"
 #include "mpv/render.h"
 #include "mpv/stream_cb.h"
+#include "video/out/vulkan/context.h"

 extern const struct mp_scripting mp_scripting_lua;
 extern const struct mp_scripting mp_scripting_cplugin;
@@ -376,6 +377,8 @@ static void init_sym_table(struct mp_script_args *args, void *lib) {

     INIT_SYM(mpv_stream_cb_add_ro);

+    INIT_SYM(ra_vk_ctx_init);
+    INIT_SYM(ra_vk_ctx_uninit);
 #undef INIT_SYM
 }

diff --git a/video/out/gpu/context.c b/video/out/gpu/context.c
index 60c0641a70..9ce32d9566 100644
--- a/video/out/gpu/context.c
+++ b/video/out/gpu/context.c
@@ -50,6 +50,7 @@ extern const struct ra_ctx_fns ra_ctx_vulkan_xlib;
 extern const struct ra_ctx_fns ra_ctx_vulkan_android;
 extern const struct ra_ctx_fns ra_ctx_vulkan_display;
 extern const struct ra_ctx_fns ra_ctx_vulkan_mac;
+extern const struct ra_ctx_fns ra_ctx_vulkan_soia;

 /* Direct3D 11 */
 extern const struct ra_ctx_fns ra_ctx_d3d11;
@@ -94,6 +95,7 @@ static const struct ra_ctx_fns *const contexts[] = {
     &ra_ctx_vulkan_xlib,
 #endif
 #if HAVE_COCOA && HAVE_SWIFT
+    &ra_ctx_vulkan_soia,
     &ra_ctx_vulkan_mac,
 #endif
 #endif
diff --git a/video/out/vulkan/context.h b/video/out/vulkan/context.h
index c3013edbd1..ebcce72c7f 100644
--- a/video/out/vulkan/context.h
+++ b/video/out/vulkan/context.h
@@ -2,10 +2,11 @@

 #include "video/out/gpu/context.h"
 #include "common.h"
+#include "mpv/client.h"

 // Helpers for ra_ctx based on ra_vk. These initialize ctx->ra and ctx->swchain.
-void ra_vk_ctx_uninit(struct ra_ctx *ctx);
-bool ra_vk_ctx_init(struct ra_ctx *ctx, struct mpvk_ctx *vk,
+MPV_EXPORT void ra_vk_ctx_uninit(struct ra_ctx *ctx);
+MPV_EXPORT bool ra_vk_ctx_init(struct ra_ctx *ctx, struct mpvk_ctx *vk,
                     struct ra_ctx_params params,
                     VkPresentModeKHR preferred_mode);
PATCH
}

echo "Downloading mpv v${MPV_VERSION}..."
rm -rf "$MPV_DIR"
mkdir -p "$MPV_DIR"
curl --fail --location --retry 3 --retry-delay 2 --output "$TARBALL" "$SOURCE_URL"
tar -zxf "$TARBALL" -C "$MPV_DIR" --strip-components=1 && apply_patch
echo "$MPV_VERSION" > "$VERSION_FILE"
rm -f "$TARBALL"
echo "Done: $MPV_DIR"
