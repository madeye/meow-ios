#!/usr/bin/env bash
# Build mihomo-ios Go module as a static C-archive for iOS device +
# simulator, then wrap into an XCFramework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_DIR="$ROOT/core/go/mihomo-ios"
OUT_DIR="$ROOT/MeowCore/Frameworks"
HEADER_DST="$ROOT/MeowCore/include/mihomo_go.h"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if ! command -v go >/dev/null 2>&1; then
    echo "error: go toolchain not found" >&2
    exit 1
fi

# Trim symbols for a smaller binary; the NetworkExtension memory budget is
# tight.
LDFLAGS="-s -w"

build_slice() {
    local goarch="$1" sdk="$2" sim="$3" out="$4" header_out="$5"
    local sdk_path
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local cc
    cc="$(xcrun --sdk "$sdk" --find clang)"

    local cflags="-arch $goarch -isysroot $sdk_path -mios-version-min=26.0"
    if [[ "$sim" == "1" ]]; then
        cflags="-arch $goarch -isysroot $sdk_path -mios-simulator-version-min=26.0"
    fi

    echo "==> go build-archive goos=ios goarch=$goarch sdk=$sdk"
    (
        cd "$GO_DIR"
        CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" \
            CC="$cc" \
            CGO_CFLAGS="$cflags" \
            CGO_LDFLAGS="$cflags" \
            go build -buildmode=c-archive \
                -trimpath \
                -ldflags "$LDFLAGS" \
                -o "$out" \
                .
    )

    if [[ -f "${out%.a}.h" ]]; then
        cp "${out%.a}.h" "$header_out"
    fi
}

DEVICE_LIB="$STAGE/device/libmihomo_ios.a"
SIM_LIB="$STAGE/sim/libmihomo_ios.a"
mkdir -p "$(dirname "$DEVICE_LIB")" "$(dirname "$SIM_LIB")"

build_slice arm64 iphoneos 0 "$DEVICE_LIB" "$STAGE/mihomo_go.h"
build_slice arm64 iphonesimulator 1 "$SIM_LIB" "$STAGE/mihomo_go.sim.h"

# Prefer the device-generated header — both slices export the same symbols.
if [[ -f "$STAGE/mihomo_go.h" ]]; then
    cp "$STAGE/mihomo_go.h" "$HEADER_DST"
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/MihomoGo.xcframework"

HEADERS_STAGE="$STAGE/headers"
mkdir -p "$HEADERS_STAGE"
cp "$HEADER_DST" "$HEADERS_STAGE/mihomo_go.h"

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADERS_STAGE" \
    -library "$SIM_LIB" -headers "$HEADERS_STAGE" \
    -output "$OUT_DIR/MihomoGo.xcframework"

echo "==> wrote $OUT_DIR/MihomoGo.xcframework"
