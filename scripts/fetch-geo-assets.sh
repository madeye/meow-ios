#!/usr/bin/env bash
# Fetches Country.mmdb from MetaCubeX/meta-rules-dat and stages it for the
# app bundle. We pin by **commit SHA + artifact SHA-256**, not tag: upstream
# uses only a rolling `latest` tag (reassigned hourly) and a rolling `release`
# branch (force-pushed), so there is no stable upstream tag to point at.
# Commit SHAs are immutable; the artifact hash is defense-in-depth against
# tampering or orphaned-commit GC.
#
# To refresh: bump UPSTREAM_COMMIT to the new `release` branch HEAD, download
# the artifact manually, recompute its SHA-256, update EXPECTED_SHA256 and
# App/Resources/geox/README.md's fetch-date line, then land the SHA bumps
# and README update in a single PR so the diff shows both numbers changing
# together.

set -euo pipefail

UPSTREAM_REPO="MetaCubeX/meta-rules-dat"
UPSTREAM_COMMIT="f6d744b8a4a9073899d77be8de5a6fcd2fb0e755"
UPSTREAM_ARTIFACT="country.mmdb"
EXPECTED_SHA256="7640321a66b2bf8fa23b599a14d473e4c98c10f173add1717b7f7cb34ae5c864"
EXPECTED_SIZE_BYTES=8639163

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$REPO_ROOT/App/Resources/geox"
DEST_FILE="$DEST_DIR/Country.mmdb"
TMP_FILE="$(mktemp -t country.mmdb.XXXXXX)"
trap 'rm -f "$TMP_FILE"' EXIT

URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}/${UPSTREAM_ARTIFACT}"

mkdir -p "$DEST_DIR"

if [ -f "$DEST_FILE" ]; then
    EXISTING_SIZE=$(wc -c <"$DEST_FILE" | tr -d ' ')
    EXISTING_SHA256=$(shasum -a 256 "$DEST_FILE" | awk '{print $1}')
    if [ "$EXISTING_SIZE" = "$EXPECTED_SIZE_BYTES" ] && [ "$EXISTING_SHA256" = "$EXPECTED_SHA256" ]; then
        echo "==> Country.mmdb already staged at ${DEST_FILE} (sha256 match) — skipping fetch"
        exit 0
    fi
    echo "==> Existing Country.mmdb does not match pin (size=${EXISTING_SIZE} sha256=${EXISTING_SHA256}); refetching"
fi

echo "==> Fetching ${URL}"
curl --fail --silent --show-error --location --output "$TMP_FILE" "$URL"

ACTUAL_SIZE=$(wc -c <"$TMP_FILE" | tr -d ' ')
if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE_BYTES" ]; then
    echo "ERROR: size mismatch. expected=${EXPECTED_SIZE_BYTES} actual=${ACTUAL_SIZE}" >&2
    exit 1
fi

ACTUAL_SHA256=$(shasum -a 256 "$TMP_FILE" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "ERROR: SHA-256 mismatch. expected=${EXPECTED_SHA256} actual=${ACTUAL_SHA256}" >&2
    exit 1
fi

mv "$TMP_FILE" "$DEST_FILE"
trap - EXIT

echo "==> Verified Country.mmdb (${ACTUAL_SIZE} bytes, sha256=${ACTUAL_SHA256})"
echo "==> Staged at ${DEST_FILE}"
