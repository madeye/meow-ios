#!/usr/bin/env bash
# Build a Release IPA signed for App Store distribution and upload it
# directly to App Store Connect (TestFlight).
#
# Output: build/meow-ios-appstore.xcarchive (kept for symbol upload)
#         build/export-appstore/ (xcodebuild upload artefacts)
#
# Companion to:
#   scripts/build-adhoc.sh             -- Ad Hoc IPA
#   scripts/upload-testflight-metadata.py -- pushes whats_new + beta info
#
# Auth uses the production App Store Connect API key (team from prod.env):
#   ASC_KEY_ID    = 9FU24T97RY
#   ASC_ISSUER_ID = <set in prod.env — issuer for the 9FU24T97RY key>
#   ASC_KEY_PATH  = ~/AuthKey_9FU24T97RY.p8
# These defaults plus the key path load from prod.env (gitignored; see
# prod.env.example). Each can be overridden via env var of the same name.
#
# Signing uses signingStyle=manual during export with the App Store
# provisioning profiles already installed on this Mac. Defaults match
# the freshest profiles (created 2026-04-19, expire 2027-04-19) and can
# be overridden via APP_PROFILE / PT_PROFILE env vars. This mirrors
# scripts/build-adhoc.sh; automatic cloud signing was tried but the
# ASC API key lacks the provisioning role required to mint new profiles
# during export.

set -euo pipefail

# Warn (warn-only, exit 0) if any provisioning profile UUID expires within
# 30 days. Each argument is a UUID under
# ~/Library/MobileDevice/Provisioning Profiles/. Missing profile files are
# reported as a warning but do not fail the script — the xcodebuild step
# below will surface the hard error if signing actually fails.
check_profile_expiry() {
    local profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
    local now_epoch
    now_epoch=$(date +%s)
    local threshold=$((30 * 24 * 60 * 60))
    local uuid path exp_iso exp_epoch delta
    for uuid in "$@"; do
        path="$profiles_dir/$uuid.mobileprovision"
        if [[ ! -f "$path" ]]; then
            echo "WARNING: provisioning profile $uuid not found at $path" >&2
            continue
        fi
        exp_iso=$(security cms -D -i "$path" 2>/dev/null \
            | /usr/libexec/PlistBuddy -c "Print :ExpirationDate" /dev/stdin 2>/dev/null \
            || true)
        if [[ -z "$exp_iso" ]]; then
            echo "WARNING: could not read ExpirationDate for profile $uuid" >&2
            continue
        fi
        exp_epoch=$(date -j -f "%a %b %d %T %Z %Y" "$exp_iso" +%s 2>/dev/null || echo "")
        if [[ -z "$exp_epoch" ]]; then
            echo "WARNING: could not parse ExpirationDate '$exp_iso' for $uuid" >&2
            continue
        fi
        delta=$((exp_epoch - now_epoch))
        if (( delta < threshold )); then
            local days=$((delta / 86400))
            echo "WARNING: provisioning profile $uuid expires in $days day(s) ($exp_iso)" >&2
        fi
    done
    return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Production signing config (gitignored). See prod.env.example.
if [[ -f "$ROOT/prod.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT/prod.env"
    set +a
fi

PROJECT_PATH="$ROOT/meow-ios.xcodeproj"
SCHEME="meow-ios"
ARCHIVE_PATH="$ROOT/build/meow-ios-appstore.xcarchive"
EXPORT_DIR="$ROOT/build/export-appstore"
EXPORT_PLIST="$ROOT/build/ExportOptions-appstore.plist"

# Production team id + ASC key come from prod.env (gitignored, sourced above).
# The team id is intentionally not committed.
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM_ID" ]]; then
    echo "error: DEVELOPMENT_TEAM not set. Create prod.env from prod.env.example (it is sourced automatically) or export DEVELOPMENT_TEAM." >&2
    exit 1
fi
ASC_KEY_ID="${ASC_KEY_ID:-9FU24T97RY}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/AuthKey_9FU24T97RY.p8}"

# App Store provisioning profile UUIDs already installed under
# ~/Library/MobileDevice/Provisioning Profiles/. Override via env if
# the profiles get rotated. These must be App Store profiles for the
# current com.tangzixiang.meow[.PacketTunnel] ids under team 32B45SMMQL
# ("meow AppStore" / "meow PT AppStore"). The old UUIDs here were for the
# retired io.github.madeye.meow ids on team SK4GFF6AHN; uploads only kept
# working because exportArchive silently fell back to the right profile by
# entitlement match — fragile, so point them at the correct ones.
APP_PROFILE="${APP_PROFILE:-836e9b24-7a09-486f-ac1f-7957ec360d78}"
PT_PROFILE="${PT_PROFILE:-7a37f4c1-5743-4f03-ac11-64a0fca57b4a}"

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

check_profile_expiry "$APP_PROFILE" "$PT_PROFILE"

mkdir -p "$ROOT/build"
rm -rf "$EXPORT_DIR"
if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
    rm -rf "$ARCHIVE_PATH"
fi

if [[ "$SKIP_RUST_BUILD" -eq 0 ]]; then
    "$ROOT/scripts/build-rust.sh"
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
        <key>com.tangzixiang.meow</key>
        <string>$APP_PROFILE</string>
        <key>com.tangzixiang.meow.PacketTunnel</key>
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
        ${XCCONFIG_ARG[@]+"${XCCONFIG_ARG[@]}"} \
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
