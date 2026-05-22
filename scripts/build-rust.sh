#!/usr/bin/env bash
# Build meow-ios-ffi for iOS device + simulator and pack into an XCFramework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$ROOT/core/rust/meow-ios-ffi"
OUT_DIR="$ROOT/MeowCore/Frameworks"
HEADER_SRC="$CRATE_DIR/include/meow_core.h"
HEADER_DST="$ROOT/MeowCore/include/meow_core.h"

TARGETS_REQUIRED=(aarch64-apple-ios aarch64-apple-ios-sim)
PROFILE="release"

# Match the iOS deployment target declared in project.yml so the Rust static
# libs and the Xcode targets agree on LC_BUILD_VERSION minos.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

for target in "${TARGETS_REQUIRED[@]}"; do
    if ! rustup target list --installed | grep -qx "$target"; then
        echo "==> Adding rust target $target"
        rustup target add "$target"
    fi
done

cd "$CRATE_DIR"

echo "==> cargo build --target aarch64-apple-ios (device)"
cargo build --release --target aarch64-apple-ios

echo "==> cargo build --target aarch64-apple-ios-sim (simulator)"
cargo build --release --target aarch64-apple-ios-sim

DEVICE_LIB="$CRATE_DIR/target/aarch64-apple-ios/$PROFILE/libmeow_ios_ffi.a"
SIM_LIB="$CRATE_DIR/target/aarch64-apple-ios-sim/$PROFILE/libmeow_ios_ffi.a"

if [[ ! -f "$DEVICE_LIB" || ! -f "$SIM_LIB" ]]; then
    echo "error: expected static libs missing" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/MeowCore.xcframework" "$OUT_DIR/MihomoCore.xcframework"

# Ensure the header we ship to Swift matches what cbindgen emitted.
if [[ -f "$HEADER_SRC" ]]; then
    cp "$HEADER_SRC" "$HEADER_DST"
fi
# Drop the old header path if a stale copy lingers from before the rename.
rm -f "$ROOT/MeowCore/include/mihomo_core.h"

HEADERS_STAGE="$(mktemp -d)"
cp "$HEADER_DST" "$HEADERS_STAGE/meow_core.h"

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADERS_STAGE" \
    -library "$SIM_LIB" -headers "$HEADERS_STAGE" \
    -output "$OUT_DIR/MeowCore.xcframework"

rm -rf "$HEADERS_STAGE"
echo "==> wrote $OUT_DIR/MeowCore.xcframework"
