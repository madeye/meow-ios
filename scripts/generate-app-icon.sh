#!/usr/bin/env bash
# Regenerate the iOS AppIcon PNG from the upstream Android Play Store icon
# using `sips -Z 1024` (Lanczos-ish upscale, macOS builtin — no extra deps).
#
# Source:       /Volumes/DATA/workspace/mihomo-android/fastlane/metadata/android/en-US/images/icon.png
#               — 512×512 RGBA, the Play Store listing icon, authoritative.
# Destination:  App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
#               — iOS 17+ unified-1024 AppIcon slot.
# Ratio:        2× upscale (512 → 1024). Shallow enough that Lanczos preserves
#               every feature of the smooth geometric cat (whiskers, eye
#               highlights, forehead mark, feet, ear inner highlights) with
#               shipping-quality softening.
#
# Why not SVG? We tried vtracer (default, --preset photo, and tuned
# `-p 8 -g 4 -f 2 -c 60`). Default + photo both dropped fine features
# (whiskers, ear highlights, forehead mark). Tuned preserved features but
# produced visible vector banding on the body-outline curve at 1024. vtracer
# is also not in Homebrew — it needs `cargo install vtracer`, a Rust-toolchain
# dep. sips-Lanczos beats tuned-SVG on fidelity at 1024 AND has zero extra
# deps, so Path X wins. Full write-up in the T5.2 PR body.
#
# Run this whenever the upstream Android icon changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="/Volumes/DATA/workspace/mihomo-android/fastlane/metadata/android/en-US/images/icon.png"
DST="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

main() {
    command -v sips >/dev/null || { echo "error: sips not found (macOS builtin)" >&2; exit 1; }
    [[ -f "$SRC" ]] || { echo "error: source icon not found at $SRC" >&2; exit 1; }
    mkdir -p "$(dirname "$DST")"
    sips -Z 1024 -i "$SRC" --out "$DST" >/dev/null
    echo "Wrote 1024×1024 AppIcon to $DST"
}

main "$@"
