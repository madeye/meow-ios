#!/usr/bin/env bash
# Regenerate the iOS icon assets from the authored meow artwork.
#
# Sources:      docs/appicon.png — 1024x1024 opaque home-screen icon.
#               docs/appmark.png — 1024x1024 transparent in-app mascot.
# Destinations: App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
#               App/Resources/Assets.xcassets/AppMark.imageset/AppMark.png
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON_SRC="${APP_ICON_SOURCE:-"$ROOT/docs/appicon.png"}"
MARK_SRC="${APP_MARK_SOURCE:-"$ROOT/docs/appmark.png"}"
ICON_DST="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
MARK_DST="$ROOT/App/Resources/Assets.xcassets/AppMark.imageset/AppMark.png"

render_icons() {
    command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }
    mkdir -p "$(dirname "$ICON_DST")" "$(dirname "$MARK_DST")"

    python3 - "$ICON_SRC" "$MARK_SRC" "$ICON_DST" "$MARK_DST" <<'PY'
import sys
from pathlib import Path
from PIL import Image

icon_source, mark_source, icon_destination, mark_destination = map(Path, sys.argv[1:])

with Image.open(icon_source) as image:
    if image.size != (1024, 1024):
        raise SystemExit(f"error: source icon must be 1024x1024, got {image.size}")
    image.convert("RGB").save(icon_destination, format="PNG", optimize=True)

with Image.open(mark_source) as image:
    if image.size != (1024, 1024):
        raise SystemExit(f"error: source mark must be 1024x1024, got {image.size}")
    if "A" not in image.getbands():
        raise SystemExit("error: source mark must have an alpha channel")
    image.convert("RGBA").save(mark_destination, format="PNG", optimize=True)

print(f"Wrote 1024x1024 opaque PNG to {icon_destination}")
print(f"Wrote 1024x1024 transparent mascot PNG to {mark_destination}")
PY
}

main() {
    [[ -f "$ICON_SRC" ]] || { echo "error: source icon not found at $ICON_SRC" >&2; exit 1; }
    [[ -f "$MARK_SRC" ]] || { echo "error: source mark not found at $MARK_SRC" >&2; exit 1; }
    render_icons
}

main "$@"
