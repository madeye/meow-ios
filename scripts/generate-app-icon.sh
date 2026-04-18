#!/usr/bin/env bash
# Regenerate the iOS AppIcon PNG from the upstream Android Play Store icon.
#
# Source:       /Volumes/DATA/workspace/mihomo-android/fastlane/metadata/android/en-US/images/icon.png
#               — 512×512 RGBA, the Play Store listing icon, authoritative.
# Destination:  App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
#               — iOS 17+ unified-1024 AppIcon slot.
# Ratio:        2× upscale (512 → 1024).
#
# Upscaler:     Real-ESRGAN ncnn-vulkan (realesr-animevideov3 @ -s 2) when
#               available on PATH, else macOS sips Lanczos as a zero-dep
#               fallback. Real-ESRGAN preserves whiskers / eye highlights /
#               forehead "m" / body-outline / nose detail noticeably better
#               than Lanczos on this smooth-geometric-vector source, with
#               no halo / oversharpening / color-shift artifacts. The T5.2
#               ship used sips-Lanczos and read "kind of blur" at home-screen
#               sizes — Real-ESRGAN produces ~2.9× more high-frequency
#               content at 1024 PNG and is what currently ships.
#
# Install the Real-ESRGAN binary by downloading the standalone macOS build
# from https://github.com/xinntao/Real-ESRGAN/releases (v0.2.5.0 or later,
# `realesrgan-ncnn-vulkan-*-macos.zip`), extracting, and placing
# `realesrgan-ncnn-vulkan` on your PATH together with its `models/` folder.
# Override via `REALESRGAN_BIN=/abs/path/realesrgan-ncnn-vulkan` if the
# binary lives elsewhere; the script will look next to it for the `models/`
# folder automatically.
#
# Why not SVG? vtracer (default, --preset photo, tuned `-p 8 -g 4 -f 2 -c 60`)
# either dropped fine features (whiskers, ear highlights, forehead mark) or
# produced visible vector banding on the body-outline curve at 1024. Full
# write-up in the T5.2 PR body.
#
# Run this whenever the upstream Android icon changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="/Volumes/DATA/workspace/mihomo-android/fastlane/metadata/android/en-US/images/icon.png"
DST="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

REALESRGAN_BIN="${REALESRGAN_BIN:-$(command -v realesrgan-ncnn-vulkan || true)}"

upscale_realesrgan() {
    local bin_dir models_dir
    bin_dir="$(cd "$(dirname "$REALESRGAN_BIN")" && pwd)"
    models_dir="$bin_dir/models"
    [[ -d "$models_dir" ]] || { echo "error: models/ not found next to $REALESRGAN_BIN" >&2; return 1; }
    "$REALESRGAN_BIN" -i "$SRC" -o "$DST" -n realesr-animevideov3 -s 2 -m "$models_dir" >/dev/null
    echo "Wrote 1024×1024 AppIcon (Real-ESRGAN animevideov3-x2) to $DST"
}

upscale_lanczos() {
    command -v sips >/dev/null || { echo "error: sips not found (macOS builtin)" >&2; exit 1; }
    sips -Z 1024 -i "$SRC" --out "$DST" >/dev/null
    echo "Wrote 1024×1024 AppIcon (sips Lanczos fallback) to $DST"
    echo "note: install Real-ESRGAN ncnn-vulkan for a sharper icon — see script header" >&2
}

main() {
    [[ -f "$SRC" ]] || { echo "error: source icon not found at $SRC" >&2; exit 1; }
    mkdir -p "$(dirname "$DST")"
    if [[ -n "$REALESRGAN_BIN" && -x "$REALESRGAN_BIN" ]]; then
        upscale_realesrgan
    else
        upscale_lanczos
    fi
}

main "$@"
