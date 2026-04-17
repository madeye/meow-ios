#!/usr/bin/env bash
#
# End-to-end test: meow-ios on a virtual iPhone driven by vphone-cli
# inside a SIP-disabled Tart VM (see docs/TEST_STRATEGY.md §7).
#
# Mirrors the Android script at /Volumes/DATA/workspace/meow-go/test-e2e.sh —
# boots a test proxy + subscription server on the host, then drives the
# virtual iPhone through the same 5-check connectivity gate by speaking
# the vm/vphone.sock protocol (tap / swipe / screenshot / clipboard).
#
# Status: SCAFFOLD. Blocked on T2.6 (Debug Diagnostics Panel — the
# per-check PASS/FAIL surface the harness screenshots/OCRs, format pinned
# by PRD v1.3 §4.4) and T4.1 (App Shell & Navigation — needed for the
# test-only SwiftData seeding deep link path).
#
# Required env:
#   VPHONE_HOST   SSH target where vphone-cli and the virtual iPhone live
#                 (e.g. admin@<tart-vm-ip>). Defaults to localhost when
#                 vphone-cli runs on the same machine as this script.
#   VPHONE_SOCK   Path to vm/vphone.sock on VPHONE_HOST. Default /tmp/vphone.sock.
#
# Design note: checks 3–5 lean on the in-app diagnostics panel (T2.6);
# they are NOT executed directly from the host because the real
# assertion is "traffic flowed through NEPacketTunnelProvider" — which
# is unobservable from outside the virtual iPhone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VPHONE_HOST="${VPHONE_HOST:-}"   # set by nightly.yml; empty = local vphone-cli
VPHONE_SOCK="${VPHONE_SOCK:-/tmp/vphone.sock}"

# Test proxy (same fixture shape as the Android script)
SSSERVER="${SSSERVER:-ssserver}"
SS_ADDR="0.0.0.0:8388"
SS_PASSWORD="testpassword123"
SS_METHOD="aes-256-gcm"
SS_HOST="127.0.0.1"
SS_PORT=8388
SUB_PORT=8080

SSSERVER_PID=""
HTTPD_PID=""

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    for var in HTTPD_PID SSSERVER_PID; do
        pid="${!var}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf /tmp/meow-ios-e2e
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "--- $*"; }

# vphone: send a command to the virtual iPhone over vm/vphone.sock.
# Runs on the VM if VPHONE_HOST is set, else on the local machine.
vphone() {
    if [[ -n "$VPHONE_HOST" ]]; then
        ssh "$VPHONE_HOST" "vphone-cli --sock $VPHONE_SOCK $*"
    else
        vphone-cli --sock "$VPHONE_SOCK" "$@"
    fi
}

info "Step 1: Prereqs"
[[ -f "$REPO_ROOT/meow-ios.xcodeproj/project.pbxproj" ]] || fail "Run 'xcodegen generate' first"
command -v "$SSSERVER" &>/dev/null || fail "ssserver not found — brew install shadowsocks-libev"
if [[ -z "$VPHONE_HOST" ]]; then
    command -v vphone-cli &>/dev/null || fail "vphone-cli not found — see TEST_STRATEGY §7.3 for Tart image setup"
fi

info "Step 2: ssserver on $SS_ADDR"
"$SSSERVER" -s "$SS_ADDR" -k "$SS_PASSWORD" -m "$SS_METHOD" -U &
SSSERVER_PID=$!
sleep 1
kill -0 "$SSSERVER_PID" 2>/dev/null || fail "ssserver failed to start"

info "Step 3: Subscription HTTP server on $SUB_PORT"
mkdir -p /tmp/meow-ios-e2e
SS_B64=$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 | tr -d '\n')
printf 'ss://%s@%s:%s#test-node-1\nss://%s@%s:%s#test-node-2\n' \
    "$SS_B64" "$SS_HOST" "$SS_PORT" "$SS_B64" "$SS_HOST" "$SS_PORT" \
    | base64 | tr -d '\n' > /tmp/meow-ios-e2e/nodelist.txt
(cd /tmp/meow-ios-e2e && python3 -m http.server "$SUB_PORT") &
HTTPD_PID=$!
sleep 1
kill -0 "$HTTPD_PID" 2>/dev/null || fail "HTTP server failed to start"

info "Step 4: Confirm virtual iPhone is up (vphone-cli)"
vphone status || fail "vphone-cli not responsive on $VPHONE_SOCK — boot the VM and install the app before running this script (see nightly.yml)"

info "Step 5: Seed a test profile via deep link"
# TODO (T4.1): deep link handler that seeds SwiftData with a profile pointing
# at http://<tart-host>:$SUB_PORT/nodelist.txt. vphone-cli supports clipboard
# → open URL flow; use it so we do not need host-to-VM networking hacks.
# vphone clipboard set "meow://test/seed?url=http://${SS_HOST}:${SUB_PORT}/nodelist.txt"
# vphone open-url-from-clipboard
info "  TODO: seed profile — blocked on T4.1 deep-link handler"

info "Step 6: Tap Connect and wait for Connected state"
# vphone tap 200 420           # coords for Connect button (from §7.5 page object)
# vphone screenshot build/e2e/connected.png
# scripts/assert-ocr.py build/e2e/connected.png "Connected" || fail "VPN did not connect within 10s"
info "  TODO: tap+wait — blocked on T4.2 Home Screen (Connect button coords stable)"

info "Step 7: Run 5-check connectivity gate via in-app diagnostics panel"
# The app exposes a debug-only 'Diagnostics' screen (T2.6) that runs the
# same five meow_engine_test_* FFI calls the Android CLI does. The
# harness navigates to it, taps Run, and screenshots the result table.
#
# The panel's output format is frozen by PRD §4.4:
#   TUN_EXISTS: PASS
#   DNS_OK: PASS
#   TCP_PROXY_OK: PASS
#   HTTP_204_OK: PASS
#   MEM_OK: PASS
# (or FAIL(<reason>) per row). The parser in MeowShared/MeowModels
# (DiagnosticsLabelParser) is shared with the XCUITest bundle, so this
# harness can consume the same grammar.
#
#   vphone tap <diagnostics-tab>
#   vphone tap <run-diagnostics-button>
#   sleep 15
#   vphone screenshot build/e2e/diagnostics.png
#   scripts/assert-diagnostics-pass.py build/e2e/diagnostics.png \
#       TUN_EXISTS DNS_OK TCP_PROXY_OK HTTP_204_OK MEM_OK
#
# The Python helper OCRs the five rows and fails if any row's value is
# not the exact string "PASS". Aggregate format matches the Android
# script's table so the two are directly comparable in PR summaries.
info "  TODO: diagnostics-panel gate — blocked on T2.6 + T4.2"

info "Step 8: Collect artifacts"
mkdir -p "$REPO_ROOT/build/e2e"
# vphone screenshot "$REPO_ROOT/build/e2e/final.png" || true

info "SCAFFOLD COMPLETE — fill in steps 5–7 once vphone-cli image is baked and T2.6/T4.2 land"
