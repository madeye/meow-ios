#!/usr/bin/env bash
# Capture App Store screenshots from the iOS Simulator without UI automation.
#
# Each screen is shown by launching the app with `-UITests -ResetState
# -screenshotTab <tab>` (honored only in UI-test builds; see ContentView.
# initialTab) and grabbed with `simctl io screenshot`. This works identically
# on iPhone and iPad (no tab-bar element to locate) and in every language.
#
# Output: fastlane/screenshots/<locale>/<Device>-<NN><Screen>.png — laid out so
# `fastlane deliver` can upload it (deliver categorizes by pixel size).
#
# Prereq: build the app for the simulator first, e.g.
#   xcodebuild build -allowProvisioningUpdates -xcconfig Local.xcconfig \
#     -project meow-ios.xcodeproj -scheme meow-ios -configuration Debug \
#     -destination 'generic/platform=iOS Simulator' \
#     -derivedDataPath build/DerivedData-snapshot DEVELOPMENT_TEAM=32B45SMMQL
# Keep simulator signing enabled: App Group entitlements are required even
# though the packet tunnel itself is mocked in simulator builds.
# No `set -e`: simulator boot/install/launch return transient non-zero codes we
# tolerate (we verify success by the captured PNG instead).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.tangzixiang.meow"
APP="${APP:-$(find build/DerivedData-snapshot/Build/Products -name 'meow-ios.app' -path '*iphonesimulator*' 2>/dev/null | head -1)}"
OUT_ROOT="$ROOT/fastlane/screenshots"

[[ -d "$APP" ]] || { echo "error: simulator app not found ($APP). Build it first." >&2; exit 1; }
echo "==> App: $APP"

# Required device sizes: iPhone 6.9" + iPad 13".
DEVICE_NAMES=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
# locale -> AppleLanguages token
LOCALES=("en-US" "zh-Hans")
# NN<Screen>:tab-tag
SCREENS=("01Subscriptions:subscriptions" "02ProxyGroups:proxyGroups" "03Traffic:traffic" "04Settings:settings")

udid_for() { xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'; }

rm -rf "$OUT_ROOT"
for locale in "${LOCALES[@]}"; do mkdir -p "$OUT_ROOT/$locale"; done

for dev in "${DEVICE_NAMES[@]}"; do
    udid="$(udid_for "$dev")"
    [[ -n "$udid" ]] || { echo "warning: no simulator '$dev', skipping" >&2; continue; }
    # Space-free token for filenames — simctl io screenshot rejects spaced paths.
    devkey="$(echo "$dev" | tr -d ' ' | tr -d '()-')"
    echo "==> $dev ($udid) [$devkey]"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
    xcrun simctl install "$udid" "$APP" || { echo "warning: install failed on $dev" >&2; continue; }
    # Clean marketing status bar (9:41, full battery/signal).
    xcrun simctl status_bar "$udid" override \
        --time "09:41" --batteryState charged --batteryLevel 100 \
        --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
        --operatorName "" >/dev/null 2>&1 || true

    for locale in "${LOCALES[@]}"; do
        loc_underscore="${locale//-/_}"
        for entry in "${SCREENS[@]}"; do
            name="${entry%%:*}"; tab="${entry##*:}"
            xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
            xcrun simctl launch "$udid" "$BUNDLE_ID" \
                -UITests -ResetState \
                -AppleLanguages "($locale)" -AppleLocale "$loc_underscore" \
                -screenshotTab "$tab" >/dev/null
            sleep 3
            out="$OUT_ROOT/$locale/${devkey}-${name}.png"
            # CoreSimulator (simctl io) is sandboxed and cannot write onto
            # secondary volumes (e.g. /Volumes/DATA) — "Operation not permitted".
            # Capture to a temp path it can write, then copy into place via bash.
            tmp="/tmp/meowshot-$$-${devkey}-${locale}-${name}.png"
            if xcrun simctl io "$udid" screenshot "$tmp" >/dev/null 2>&1 && [[ -s "$tmp" ]]; then
                cp "$tmp" "$out"
                echo "    $locale/${devkey}-${name}.png"
            else
                echo "    FAILED $locale/${devkey}-${name}.png" >&2
            fi
            rm -f "$tmp"
        done
    done
    xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
done

echo "==> Done. $(find "$OUT_ROOT" -name '*.png' | wc -l | tr -d ' ') screenshots in $OUT_ROOT"
