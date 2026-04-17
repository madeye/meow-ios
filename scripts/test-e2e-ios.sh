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
# Status: P1 — SS fixture scaffold live (docs/TEST_FIXTURES.md §6). vphone
# drive steps (5-7) remain TODO, blocked on T4.1 (deep-link handler) and
# T4.2 (Home Screen — Connect button coords / accessibilityIdentifiers).
# T2.6 Diagnostics Panel is live so Step 7 anchors are now defined; wiring
# the OCR flow lands with the E2E gate flip itself.
#
# Required env:
#   VPHONE_HOST           SSH target where vphone-cli and the virtual iPhone live
#                         (e.g. admin@<tart-vm-ip>). Empty = local vphone-cli.
#   VPHONE_SOCK           Path to vm/vphone.sock on VPHONE_HOST. Default /tmp/vphone.sock.
#
# Optional env:
#   MEOW_FIXTURE_SEEDED   If set, use fixed seed credentials + a stable fixture
#                         directory (/tmp/meow-fixtures/seeded). Intended for
#                         local dev — the dev can point a running iOS build at
#                         http://127.0.0.1:18080/clash.yaml across reruns.
#                         CI (default, empty) generates ephemeral creds + a
#                         UUID-scoped dir, wiped on exit.
#   SS_METHOD             Cipher override. Default aes-256-gcm.
#   SUB_PORT              Subscription HTTP port. Default 18080 (claimed in
#                         TEST_FIXTURES.md §5 for Tart VM port bookkeeping).
#
# Design note: checks 3–5 lean on the in-app diagnostics panel (T2.6);
# they are NOT executed directly from the host because the real
# assertion is "traffic flowed through NEPacketTunnelProvider" — which
# is unobservable from outside the virtual iPhone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VPHONE_HOST="${VPHONE_HOST:-}"
VPHONE_SOCK="${VPHONE_SOCK:-/tmp/vphone.sock}"

MEOW_FIXTURE_SEEDED="${MEOW_FIXTURE_SEEDED:-}"

SSSERVER="${SSSERVER:-ssserver}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"
SS_HOST="127.0.0.1"
SUB_PORT="${SUB_PORT:-18080}"

FIXTURE_BASE="/tmp/meow-fixtures"

if [[ -n "$MEOW_FIXTURE_SEEDED" ]]; then
    FIXTURE_DIR="${FIXTURE_BASE}/seeded"
    SS_PASSWORD="${SS_PASSWORD:-meow-seeded-local-dev-password}"
    SS_PORT="${SS_PORT:-18388}"
else
    FIXTURE_DIR="${FIXTURE_BASE}/$(uuidgen | tr 'A-Z' 'a-z')"
    SS_PASSWORD="$(openssl rand -hex 16)"
    # Pick a free ephemeral port so parallel CI runs don't collide.
    SS_PORT="$(python3 -c 'import socket
s=socket.socket(); s.bind(("",0))
print(s.getsockname()[1]); s.close()')"
fi
SS_ADDR="0.0.0.0:${SS_PORT}"

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
    # Ephemeral run — wipe. Seeded run — preserve for dev inspection.
    if [[ -z "$MEOW_FIXTURE_SEEDED" && -n "${FIXTURE_DIR:-}" && -d "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "--- $*"; }

# vphone: send a command to the virtual iPhone over vm/vphone.sock.
vphone() {
    if [[ -n "$VPHONE_HOST" ]]; then
        ssh "$VPHONE_HOST" "vphone-cli --sock $VPHONE_SOCK $*"
    else
        vphone-cli --sock "$VPHONE_SOCK" "$@"
    fi
}

info "Step 1: Prereqs"
[[ -f "$REPO_ROOT/meow-ios.xcodeproj/project.pbxproj" ]] || fail "Run 'xcodegen generate' first"
if ! command -v "$SSSERVER" &>/dev/null; then
    info "ssserver not found — attempting 'brew install shadowsocks-rust'"
    brew install shadowsocks-rust || fail "brew install shadowsocks-rust failed (see docs/TEST_FIXTURES.md §5)"
fi
if [[ -z "$VPHONE_HOST" ]] && ! command -v vphone-cli &>/dev/null; then
    info "vphone-cli not found — fixture scaffold will run, but vphone drive steps will skip"
fi

if [[ -n "$MEOW_FIXTURE_SEEDED" ]]; then SEEDED_LABEL="yes"; else SEEDED_LABEL="no"; fi
info "Step 2: Fixture dir ($FIXTURE_DIR) — seeded=${SEEDED_LABEL}"
# Seeded mode: re-create fresh each run so a half-finished previous run can't poison state.
if [[ -n "$MEOW_FIXTURE_SEEDED" && -d "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
fi
mkdir -p "$FIXTURE_DIR"

info "Step 3: Start ssserver (method=$SS_METHOD, port=$SS_PORT)"
"$SSSERVER" -s "$SS_ADDR" -k "$SS_PASSWORD" -m "$SS_METHOD" -U \
    >"$FIXTURE_DIR/ssserver.log" 2>&1 &
SSSERVER_PID=$!
sleep 0.5
kill -0 "$SSSERVER_PID" 2>/dev/null || fail "ssserver failed to start — see $FIXTURE_DIR/ssserver.log"

info "Step 4: Write Clash subscription YAML ($FIXTURE_DIR/clash.yaml)"
cat >"$FIXTURE_DIR/clash.yaml" <<EOF
# meow-ios fixture subscription — generated by scripts/test-e2e-ios.sh
mixed-port: 7890
external-controller: 127.0.0.1:9090
mode: rule
log-level: info
proxies:
  - name: meow-fixture-ss
    type: ss
    server: ${SS_HOST}
    port: ${SS_PORT}
    cipher: ${SS_METHOD}
    password: "${SS_PASSWORD}"
proxy-groups:
  - name: meow-auto
    type: select
    proxies:
      - meow-fixture-ss
      - DIRECT
rules:
  - MATCH,meow-auto
EOF

info "Step 5: Serve subscription on port $SUB_PORT"
# `exec` so $! captures the python PID directly, not a transient subshell.
# Without it, cleanup's kill would hit the subshell (already gone) and
# leak an orphan python bound to $SUB_PORT.
(cd "$FIXTURE_DIR" && exec python3 -m http.server "$SUB_PORT" \
    >"$FIXTURE_DIR/httpd.log" 2>&1) &
HTTPD_PID=$!
sleep 0.5
kill -0 "$HTTPD_PID" 2>/dev/null || fail "http.server failed to start — see $FIXTURE_DIR/httpd.log"

SUBSCRIPTION_URL="http://${SS_HOST}:${SUB_PORT}/clash.yaml"

# Machine-parseable fixture summary — downstream harness (Swift XCUITest, etc.)
# can `eval "$(./test-e2e-ios.sh --emit-env)"` once that mode is added in P2,
# or parse these lines directly.
cat <<EOF

=== Fixture ready ===
FIXTURE_DIR=${FIXTURE_DIR}
SUBSCRIPTION_URL=${SUBSCRIPTION_URL}
SS_HOST=${SS_HOST}
SS_PORT=${SS_PORT}
SS_METHOD=${SS_METHOD}
SS_PASSWORD=${SS_PASSWORD}

EOF

if [[ -z "$VPHONE_HOST" ]] && ! command -v vphone-cli &>/dev/null; then
    info "No vphone-cli — stopping after fixture setup (scaffold-only mode)"
    info "Leave fixture up? Set MEOW_FIXTURE_KEEPALIVE=1 and trap on Ctrl-C"
    if [[ -n "${MEOW_FIXTURE_KEEPALIVE:-}" ]]; then
        info "Keepalive mode — fixture stays up until Ctrl-C"
        wait "$SSSERVER_PID"
    fi
    exit 0
fi

info "Step 6: Confirm virtual iPhone is up (vphone-cli)"
vphone status || fail "vphone-cli not responsive on $VPHONE_SOCK — boot the VM and install the app before running this script (see nightly.yml)"

info "Step 7: Seed a test profile via deep link"
# TODO (T4.1): deep link handler that seeds SwiftData with a profile pointing
# at $SUBSCRIPTION_URL. vphone-cli supports clipboard → open URL flow; use it
# so we do not need host-to-VM networking hacks.
# vphone clipboard set "meow://test/seed?url=${SUBSCRIPTION_URL}"
# vphone open-url-from-clipboard
info "  TODO: seed profile — blocked on T4.1 deep-link handler"

info "Step 8: Tap Connect and wait for Connected state"
# TODO (T4.2): once Home Screen ships with stable accessibilityIdentifiers,
# drive the VPN toggle and assert Connected state via screenshot+OCR.
info "  TODO: tap+wait — blocked on T4.2 Home Screen"

info "Step 9: Run 5-check connectivity gate via in-app diagnostics panel"
# T2.6 landed. Anchors (per Dev's ship message):
#   - accessibilityIdentifier "diagnostics.button.run" on Run button
#   - accessibilityIdentifier "diagnostics.row.<KEY>" on each row, KEY ∈
#     {TUN_EXISTS, DNS_OK, TCP_PROXY_OK, HTTP_204_OK, MEM_OK}
#   - Grammar "KEY: PASS" or "KEY: FAIL(<reason>)" via DiagnosticsLabelParser.
#   - Reachable via meow://diagnostics deep link (CFBundleURLTypes registered).
#
#   vphone clipboard set "meow://diagnostics"
#   vphone open-url-from-clipboard
#   vphone tap-id diagnostics.button.run
#   sleep 15
#   vphone screenshot build/e2e/diagnostics.png
#   scripts/assert-diagnostics-pass.py build/e2e/diagnostics.png \
#       TUN_EXISTS DNS_OK TCP_PROXY_OK HTTP_204_OK MEM_OK
#
# Wiring lands with the 5-check E2E gate flip (still disabled pending T4.2
# Home Screen to make the OCR surface production-stable).
info "  TODO: diagnostics-panel gate — pending T4.2 to stabilize OCR surface"

info "Step 10: Collect artifacts"
mkdir -p "$REPO_ROOT/build/e2e"

info "P1 SCAFFOLD COMPLETE — steps 7–9 land with T4.1/T4.2 + gate flip"
