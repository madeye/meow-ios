#!/usr/bin/env bash
# Regenerate the iOS and docs app icons from the meow-rs website logo.
#
# Source:       ../meow-rs/website/public/logo.svg
#               — 32×32 SVG, authoritative web pixel-art mark.
# Destinations: App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
#               docs/appicon.png
#               — 1024×1024 opaque PNGs.
#
# The SVG is first rendered on its native 32×32 grid, then scaled to 1024×1024
# with nearest-neighbor resampling so the home-screen icon keeps the same
# pixel-art silhouette as the web logo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MEOW_RS_ROOT="${MEOW_RS_ROOT:-"$ROOT/../meow-rs"}"
SRC="$MEOW_RS_ROOT/website/public/logo.svg"
APP_ICON_DST="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
DOCS_ICON_DST="$ROOT/docs/appicon.png"
BACKGROUND_COLOR="${BACKGROUND_COLOR:-#FFF4E8}"

render_icon() {
    local native_png
    command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

    ICON_TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$ICON_TMPDIR"' EXIT
    native_png="$ICON_TMPDIR/logo-32.png"

    rsvg-convert -w 32 -h 32 -b "$BACKGROUND_COLOR" -o "$native_png" "$SRC"
    mkdir -p "$(dirname "$APP_ICON_DST")" "$(dirname "$DOCS_ICON_DST")"

    python3 - "$native_png" "$APP_ICON_DST" "$DOCS_ICON_DST" <<'PY'
import sys
from pathlib import Path
from PIL import Image

source = Path(sys.argv[1])
destinations = [Path(path) for path in sys.argv[2:]]

with Image.open(source) as image:
    icon = image.convert("RGB").resize((1024, 1024), Image.Resampling.NEAREST)
    for destination in destinations:
        icon.save(destination, format="PNG", optimize=True)
        print(f"Wrote 1024x1024 opaque PNG to {destination}")
PY
}

main() {
    [[ -f "$SRC" ]] || { echo "error: source logo not found at $SRC" >&2; exit 1; }
    render_icon
}

main "$@"
