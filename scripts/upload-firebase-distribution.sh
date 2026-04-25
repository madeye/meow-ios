#!/usr/bin/env bash
# Upload the Ad Hoc IPA to Firebase App Distribution.
#
# Reads release notes from metadata/testflight/whats_new/<build>.txt to keep
# parity with what TestFlight testers see. Distributes to a tester group named
# "beta" by default (override with --groups).
#
# Prereqs: `firebase login` (one-time), `scripts/build-adhoc.sh` already ran.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FIREBASE_APP_ID="${FIREBASE_APP_ID:-1:634173336877:ios:74690155062764080b77a4}"
IPA="${IPA:-$ROOT/build/export-adhoc/meow-ios.ipa}"
TESTER_GROUPS="${TESTER_GROUPS:-beta}"
RELEASE_NOTES_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa) IPA="$2"; shift 2;;
        --groups) TESTER_GROUPS="$2"; shift 2;;
        --release-notes-file) RELEASE_NOTES_FILE="$2"; shift 2;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -f "$IPA" ]] || { echo "error: missing IPA at $IPA — run scripts/build-adhoc.sh first" >&2; exit 1; }

if [[ -z "$RELEASE_NOTES_FILE" ]]; then
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ROOT/App/Info.plist")
    RELEASE_NOTES_FILE="$ROOT/metadata/testflight/whats_new/${BUILD_NUMBER}.txt"
fi

if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
    echo "warning: release notes file not found: $RELEASE_NOTES_FILE — uploading without notes" >&2
    NOTES_ARGS=()
else
    NOTES_ARGS=(--release-notes-file "$RELEASE_NOTES_FILE")
fi

echo "==> Distributing $IPA to Firebase app $FIREBASE_APP_ID (groups: $TESTER_GROUPS)"
firebase appdistribution:distribute "$IPA" \
    --app "$FIREBASE_APP_ID" \
    --groups "$TESTER_GROUPS" \
    "${NOTES_ARGS[@]}"

echo "==> Done."
