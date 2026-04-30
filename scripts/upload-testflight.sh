#!/usr/bin/env bash
# Build a Release IPA signed for App Store distribution and upload it
# directly to App Store Connect (TestFlight).
#
# Output: build/meow-ios-appstore.xcarchive (kept for symbol upload)
#         build/export-appstore/ (xcodebuild upload artefacts)
#
# Companion to:
#   scripts/build-adhoc.sh             -- Firebase Ad Hoc IPA
#   scripts/upload-testflight-metadata.py -- pushes whats_new + beta info
#
# Auth uses the App Store Connect API key configured in CLAUDE.md:
#   ASC_KEY_ID    = 5MC8U9Z7P9
#   ASC_ISSUER_ID = 1200242f-e066-47cc-9ac8-b3affd0eee32
#   ASC_KEY_PATH  = ~/.appstoreconnect/AuthKey_5MC8U9Z7P9.p8
# Each can be overridden via env var of the same name.
#
# Signing uses signingStyle=manual during export with the App Store
# provisioning profiles already installed on this Mac. Defaults match
# the freshest profiles (created 2026-04-19, expire 2027-04-19) and can
# be overridden via APP_PROFILE / PT_PROFILE env vars. This mirrors
# scripts/build-adhoc.sh; automatic cloud signing was tried but the
# ASC API key lacks the provisioning role required to mint new profiles
# during export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="$ROOT/meow-ios.xcodeproj"
SCHEME="meow-ios"
ARCHIVE_PATH="$ROOT/build/meow-ios-appstore.xcarchive"
EXPORT_DIR="$ROOT/build/export-appstore"
EXPORT_PLIST="$ROOT/build/ExportOptions-appstore.plist"

TEAM_ID="${DEVELOPMENT_TEAM:-SK4GFF6AHN}"
ASC_KEY_ID="${ASC_KEY_ID:-5MC8U9Z7P9}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-1200242f-e066-47cc-9ac8-b3affd0eee32}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/AuthKey_5MC8U9Z7P9.p8}"

# App Store provisioning profile UUIDs already installed under
# ~/Library/MobileDevice/Provisioning Profiles/. Override via env if
# the profiles get rotated.
APP_PROFILE="${APP_PROFILE:-1e7fc11e-15c4-4734-aca7-5c44014c396f}"
PT_PROFILE="${PT_PROFILE:-7b6ce2a5-8843-47b7-991b-5a99f7db9ab7}"

SKIP_RUST_BUILD=0
SKIP_ARCHIVE=0
SKIP_UPLOAD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-rust-build) SKIP_RUST_BUILD=1; shift;;
        --skip-archive)    SKIP_ARCHIVE=1; SKIP_RUST_BUILD=1; shift;;
        --skip-upload)     SKIP_UPLOAD=1; shift;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: App Store Connect API key not found at $ASC_KEY_PATH" >&2
    echo "       Set ASC_KEY_PATH or place the .p8 at the default location." >&2
    exit 1
fi

mkdir -p "$ROOT/build"
rm -rf "$EXPORT_DIR"
if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
    rm -rf "$ARCHIVE_PATH"
fi

if [[ "$SKIP_RUST_BUILD" -eq 0 ]]; then
    "$ROOT/scripts/build-rust.sh"
fi
if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
    "$ROOT/scripts/fetch-geo-assets.sh"
fi

# destination=upload makes -exportArchive submit the IPA to App Store
# Connect after exporting (Xcode 14+). method=app-store-connect (the
# successor to the deprecated method=app-store) lands the build in
# TestFlight processing.
cat >"$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>io.github.madeye.meow</key>
        <string>$APP_PROFILE</string>
        <key>io.github.madeye.meow.PacketTunnel</key>
        <string>$PT_PROFILE</string>
    </dict>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
EOF

XCCONFIG_ARG=()
if [[ -f "$ROOT/Local.xcconfig" ]]; then
    XCCONFIG_ARG=(-xcconfig "$ROOT/Local.xcconfig")
fi

if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
    echo "==> Archiving (App Store)"
    xcodebuild -allowProvisioningUpdates \
        "${XCCONFIG_ARG[@]}" \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$ROOT/build/DerivedData" \
        -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
        archive \
        "DEVELOPMENT_TEAM=$TEAM_ID" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        -authenticationKeyPath "$ASC_KEY_PATH"
else
    [[ -d "$ARCHIVE_PATH" ]] || { echo "error: --skip-archive given but archive missing at $ARCHIVE_PATH" >&2; exit 1; }
    echo "==> Reusing existing archive at $ARCHIVE_PATH"
fi

if [[ "$SKIP_UPLOAD" -eq 1 ]]; then
    echo "==> Skipping upload (--skip-upload). Archive at $ARCHIVE_PATH"
    exit 0
fi

echo "==> Exporting + uploading to App Store Connect (TestFlight)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    -authenticationKeyPath "$ASC_KEY_PATH"

echo "==> Upload submitted. Track status in App Store Connect / TestFlight."
echo "==> Run scripts/upload-testflight-metadata.py to push the new"
echo "    metadata/testflight/whats_new notes once the build finishes processing."
