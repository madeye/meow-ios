#!/usr/bin/env bash
# Build a Release IPA signed for Ad Hoc distribution (release-testing method).
# Output: build/export-adhoc/meow-ios.ipa
#
# Companion to scripts/build-release.sh. Used for Firebase App Distribution
# delivery to manually-registered tester UDIDs.
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
        # PlistBuddy prints dates like "Mon Apr 19 12:34:56 PDT 2027".
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

PROJECT_PATH="$ROOT/meow-ios.xcodeproj"
SCHEME="meow-ios"
ARCHIVE_PATH="$ROOT/build/meow-ios-adhoc.xcarchive"
EXPORT_DIR="$ROOT/build/export-adhoc"
EXPORT_PLIST="$ROOT/build/ExportOptions-adhoc.plist"

# Ad Hoc profiles installed on this Mac (UUIDs from
# ~/Library/MobileDevice/Provisioning Profiles/)
APP_PROFILE="${APP_PROFILE:-1530eda1-0fae-4c05-bbae-d07cde47ac39}"
PT_PROFILE="${PT_PROFILE:-67929e8a-de89-4046-a21a-fad19f92071b}"

TEAM_ID="${DEVELOPMENT_TEAM:-SK4GFF6AHN}"
ASC_KEY_ID="${ASC_KEY_ID:-5MC8U9Z7P9}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-1200242f-e066-47cc-9ac8-b3affd0eee32}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/AuthKey_5MC8U9Z7P9.p8}"

SKIP_RUST_BUILD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-rust-build) SKIP_RUST_BUILD=1; shift;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

check_profile_expiry "$APP_PROFILE" "$PT_PROFILE"

mkdir -p "$ROOT/build"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

if [[ "$SKIP_RUST_BUILD" -eq 0 ]]; then
    "$ROOT/scripts/build-rust.sh"
fi

cat >"$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>release-testing</string>
    <key>destination</key>
    <string>export</string>
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

echo "==> Archiving (Ad Hoc)"
xcodebuild -allowProvisioningUpdates \
    -xcconfig "$ROOT/Local.xcconfig" \
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

echo "==> Exporting (release-testing)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    -authenticationKeyPath "$ASC_KEY_PATH"

IPA="$EXPORT_DIR/meow-ios.ipa"
[[ -f "$IPA" ]] || { echo "error: missing $IPA" >&2; exit 1; }
echo "==> Ad Hoc IPA: $IPA"
ls -la "$IPA"
