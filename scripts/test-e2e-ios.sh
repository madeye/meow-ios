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
# Status: P2 — Trojan + VLESS + VMess fixtures layered onto the P1 SS
# scaffold (docs/TEST_FIXTURES.md §6). vphone drive steps (6-9) remain
# TODO, blocked on T4.1 (deep-link handler) and T4.2 (Home Screen —
# Connect button coords / accessibilityIdentifiers). T2.6 Diagnostics
# Panel is live so Step 9 anchors are known; wiring the OCR flow lands
# with the E2E gate flip itself.
#
# Required env:
#   VPHONE_HOST           SSH target where vphone-cli and the virtual iPhone live
#                         (e.g. admin@<tart-vm-ip>). Empty = local vphone-cli.
#   VPHONE_SOCK           Path to vm/vphone.sock on VPHONE_HOST. Default /tmp/vphone.sock.
#
# Optional env:
#   MEOW_FIXTURE_PROTOCOLS  Comma-separated protocols to stand up. Default "ss".
#                           Supported: ss, trojan, vless, vmess. Unknown tokens fail;
#                           known tokens whose server binary is absent on PATH
#                           are skipped with a warning (the fixture still serves a
#                           subscription, just without that protocol's proxy entry).
#   MEOW_FIXTURE_SEEDED     If set, use fixed seed credentials + a stable fixture
#                           directory (/tmp/meow-fixtures/seeded) + stable ports.
#                           Intended for local dev — the dev can point a running
#                           iOS build at http://127.0.0.1:18080/clash.yaml across
#                           reruns. CI (default, empty) generates ephemeral creds
#                           + a UUID-scoped dir + free ports, wiped on exit.
#   SS_METHOD               SS cipher override. Default aes-256-gcm.
#   SUB_PORT                Subscription HTTP port. Default 18080 (claimed in
#                           TEST_FIXTURES.md §5 for Tart VM port bookkeeping).
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
MEOW_FIXTURE_PROTOCOLS="${MEOW_FIXTURE_PROTOCOLS:-ss}"

SSSERVER="${SSSERVER:-ssserver}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"
SS_HOST="127.0.0.1"
SUB_PORT="${SUB_PORT:-18080}"

FIXTURE_BASE="/tmp/meow-fixtures"

# alloc_port: picks an ephemeral free port by asking the kernel. Used
# for ephemeral-mode port allocation so parallel CI runs never collide.
alloc_port() {
    python3 -c 'import socket
s=socket.socket(); s.bind(("",0))
print(s.getsockname()[1]); s.close()'
}

if [[ -n "$MEOW_FIXTURE_SEEDED" ]]; then
    FIXTURE_DIR="${FIXTURE_BASE}/seeded"
    SS_PASSWORD="${SS_PASSWORD:-meow-seeded-local-dev-password}"
    SS_PORT="${SS_PORT:-18388}"
    # Seeded ports for Trojan/VLESS/VMess — mirror the SS 18388 convention.
    # Kept in docs/TEST_FIXTURES.md §5 so local-dev can pin subscription
    # profiles across reruns.
    TROJAN_PORT="${TROJAN_PORT:-18443}"
    VLESS_PORT="${VLESS_PORT:-18444}"
    VMESS_PORT="${VMESS_PORT:-18445}"
    TROJAN_PASSWORD="${TROJAN_PASSWORD:-meow-seeded-trojan-password}"
    VLESS_UUID="${VLESS_UUID:-00000000-0000-4000-8000-000000000001}"
    VMESS_UUID="${VMESS_UUID:-00000000-0000-4000-8000-000000000002}"
else
    FIXTURE_DIR="${FIXTURE_BASE}/$(uuidgen | tr 'A-Z' 'a-z')"
    SS_PASSWORD="$(openssl rand -hex 16)"
    SS_PORT="$(alloc_port)"
    TROJAN_PORT="$(alloc_port)"
    VLESS_PORT="$(alloc_port)"
    VMESS_PORT="$(alloc_port)"
    TROJAN_PASSWORD="$(openssl rand -hex 16)"
    VLESS_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
    VMESS_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
fi
SS_ADDR="0.0.0.0:${SS_PORT}"

SSSERVER_PID=""
TROJAN_PID=""
TROJAN_FALLBACK_PID=""
XRAY_VLESS_PID=""
XRAY_VMESS_PID=""
HTTPD_PID=""
KEEPALIVE_PID=""

# Track protocols that actually came up — populated by each setup function.
ENABLED_PROTOCOLS=()

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    for var in KEEPALIVE_PID HTTPD_PID XRAY_VMESS_PID XRAY_VLESS_PID TROJAN_PID TROJAN_FALLBACK_PID SSSERVER_PID; do
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
trap 'exit 130' INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "--- $*"; }
warn() { echo "WARN: $*" >&2; }

# vphone: send a command to the virtual iPhone over vm/vphone.sock.
vphone() {
    if [[ -n "$VPHONE_HOST" ]]; then
        ssh "$VPHONE_HOST" "vphone-cli --sock $VPHONE_SOCK $*"
    else
        vphone-cli --sock "$VPHONE_SOCK" "$@"
    fi
}

# Parse the protocols list once, reject unknowns loudly. Optional-binary
# skips happen later, per-protocol, so the operator sees which server
# was missing — not a generic "something failed".
IFS=',' read -r -a REQUESTED_PROTOCOLS <<<"$MEOW_FIXTURE_PROTOCOLS"
for p in "${REQUESTED_PROTOCOLS[@]}"; do
    case "$p" in
        ss|trojan|vless|vmess) ;;
        *) fail "Unknown protocol '$p' in MEOW_FIXTURE_PROTOCOLS (supported: ss,trojan,vless,vmess)" ;;
    esac
done

wants() {
    local needle="$1"
    for p in "${REQUESTED_PROTOCOLS[@]}"; do
        [[ "$p" == "$needle" ]] && return 0
    done
    return 1
}

# --- Per-protocol setup. Each writes its Clash-YAML proxy block to a
# staging file under $FIXTURE_DIR/proxies.d/<name>.yaml and appends its
# name to ENABLED_PROTOCOLS on success. Absence of the server binary is
# a warn-and-skip, not a fail — the P3 phasing in TEST_FIXTURES.md §6
# relies on this pattern for the UDP-blocked protocols.

setup_ss() {
    if ! command -v "$SSSERVER" &>/dev/null; then
        info "ssserver not found — attempting 'brew install shadowsocks-rust'"
        brew install shadowsocks-rust \
            || fail "brew install shadowsocks-rust failed (see docs/TEST_FIXTURES.md §5)"
    fi
    info "Start ssserver (method=$SS_METHOD, port=$SS_PORT)"
    "$SSSERVER" -s "$SS_ADDR" -k "$SS_PASSWORD" -m "$SS_METHOD" -U \
        >"$FIXTURE_DIR/ssserver.log" 2>&1 &
    SSSERVER_PID=$!
    sleep 0.5
    kill -0 "$SSSERVER_PID" 2>/dev/null \
        || fail "ssserver failed to start — see $FIXTURE_DIR/ssserver.log"
    cat >"$FIXTURE_DIR/proxies.d/ss.yaml" <<EOF
  - name: meow-fixture-ss
    type: ss
    server: ${SS_HOST}
    port: ${SS_PORT}
    cipher: ${SS_METHOD}
    password: "${SS_PASSWORD}"
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-ss)
}

setup_trojan() {
    if ! command -v trojan-go &>/dev/null; then
        warn "trojan-go not on PATH — skipping Trojan fixture. Install from https://github.com/p4gefau1t/trojan-go/releases or bake into the Tart base image (TEST_FIXTURES.md §5)."
        return 0
    fi
    info "Generate self-signed cert for trojan-go (CN=meow-fixture.local)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$FIXTURE_DIR/trojan-key.pem" \
        -out "$FIXTURE_DIR/trojan-cert.pem" \
        -subj "/CN=meow-fixture.local" \
        >/dev/null 2>"$FIXTURE_DIR/openssl.log" \
        || fail "openssl cert generation failed — see $FIXTURE_DIR/openssl.log"
    # trojan-go does a startup reachability probe on remote_addr:remote_port
    # (its fallback for requests that fail password auth) and refuses to run
    # if it can't connect. Stand up a tiny HTTP responder on a dedicated
    # loopback port so the probe succeeds. We never exercise this path —
    # tests always present the correct password.
    local fallback_port
    fallback_port="$(alloc_port)"
    mkdir -p "$FIXTURE_DIR/trojan-fallback"
    echo "meow-fixture-fallback" >"$FIXTURE_DIR/trojan-fallback/index.html"
    (cd "$FIXTURE_DIR/trojan-fallback" && exec python3 -m http.server "$fallback_port" \
        >"$FIXTURE_DIR/trojan-fallback.log" 2>&1) &
    TROJAN_FALLBACK_PID=$!
    sleep 0.3
    kill -0 "$TROJAN_FALLBACK_PID" 2>/dev/null \
        || fail "trojan-go fallback http.server failed to start — see $FIXTURE_DIR/trojan-fallback.log"
    cat >"$FIXTURE_DIR/trojan.json" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${TROJAN_PORT},
  "remote_addr": "127.0.0.1",
  "remote_port": ${fallback_port},
  "password": ["${TROJAN_PASSWORD}"],
  "ssl": {
    "cert": "${FIXTURE_DIR}/trojan-cert.pem",
    "key": "${FIXTURE_DIR}/trojan-key.pem",
    "sni": "meow-fixture.local"
  }
}
EOF
    info "Start trojan-go (port=$TROJAN_PORT, fallback=$fallback_port)"
    trojan-go -config "$FIXTURE_DIR/trojan.json" \
        >"$FIXTURE_DIR/trojan.log" 2>&1 &
    TROJAN_PID=$!
    sleep 0.5
    kill -0 "$TROJAN_PID" 2>/dev/null \
        || fail "trojan-go failed to start — see $FIXTURE_DIR/trojan.log"
    # skip-cert-verify is scoped to this fixture YAML only — the
    # engine's TLS on the proxied hop accepts the self-signed cert here.
    # This is NOT ATS / NSAllowsArbitraryLoads, which stays forbidden
    # per .github/workflows/ci.yml security-scan and TEST_FIXTURES §7.5.
    cat >"$FIXTURE_DIR/proxies.d/trojan.yaml" <<EOF
  - name: meow-fixture-trojan
    type: trojan
    server: ${SS_HOST}
    port: ${TROJAN_PORT}
    password: "${TROJAN_PASSWORD}"
    sni: meow-fixture.local
    skip-cert-verify: true
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-trojan)
}

# xray is the single binary backing both VLESS and VMess. We launch one
# process per protocol (separate configs) so the skip-if-absent warning
# is per-protocol and the crash blast radius stays narrow. The marginal
# cost over a shared xray process is ~8 MB RSS — acceptable for a CI
# fixture.
setup_vless() {
    if ! command -v xray &>/dev/null; then
        warn "xray not on PATH — skipping VLESS fixture. Install via 'brew install xray' or bake into the Tart base image (TEST_FIXTURES.md §5)."
        return 0
    fi
    cat >"$FIXTURE_DIR/xray-vless.json" <<EOF
{
  "log": {"loglevel": "warning", "access": "${FIXTURE_DIR}/xray-vless-access.log"},
  "inbounds": [{
    "port": ${VLESS_PORT},
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_UUID}"}],
      "decryption": "none"
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    info "Start xray (VLESS inbound, port=$VLESS_PORT)"
    xray run -config "$FIXTURE_DIR/xray-vless.json" \
        >"$FIXTURE_DIR/xray-vless.log" 2>&1 &
    XRAY_VLESS_PID=$!
    sleep 0.5
    kill -0 "$XRAY_VLESS_PID" 2>/dev/null \
        || fail "xray (VLESS) failed to start — see $FIXTURE_DIR/xray-vless.log"
    cat >"$FIXTURE_DIR/proxies.d/vless.yaml" <<EOF
  - name: meow-fixture-vless
    type: vless
    server: ${SS_HOST}
    port: ${VLESS_PORT}
    uuid: ${VLESS_UUID}
    network: tcp
    tls: false
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-vless)
}

setup_vmess() {
    if ! command -v xray &>/dev/null; then
        warn "xray not on PATH — skipping VMess fixture. Install via 'brew install xray' or bake into the Tart base image (TEST_FIXTURES.md §5)."
        return 0
    fi
    cat >"$FIXTURE_DIR/xray-vmess.json" <<EOF
{
  "log": {"loglevel": "warning", "access": "${FIXTURE_DIR}/xray-vmess-access.log"},
  "inbounds": [{
    "port": ${VMESS_PORT},
    "listen": "0.0.0.0",
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    info "Start xray (VMess inbound, port=$VMESS_PORT)"
    xray run -config "$FIXTURE_DIR/xray-vmess.json" \
        >"$FIXTURE_DIR/xray-vmess.log" 2>&1 &
    XRAY_VMESS_PID=$!
    sleep 0.5
    kill -0 "$XRAY_VMESS_PID" 2>/dev/null \
        || fail "xray (VMess) failed to start — see $FIXTURE_DIR/xray-vmess.log"
    cat >"$FIXTURE_DIR/proxies.d/vmess.yaml" <<EOF
  - name: meow-fixture-vmess
    type: vmess
    server: ${SS_HOST}
    port: ${VMESS_PORT}
    uuid: ${VMESS_UUID}
    alterId: 0
    cipher: auto
    network: tcp
    tls: false
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-vmess)
}

info "Step 1: Prereqs (protocols=${MEOW_FIXTURE_PROTOCOLS})"
[[ -f "$REPO_ROOT/meow-ios.xcodeproj/project.pbxproj" ]] || fail "Run 'xcodegen generate' first"
if [[ -z "$VPHONE_HOST" ]] && ! command -v vphone-cli &>/dev/null; then
    info "vphone-cli not found — fixture scaffold will run, but vphone drive steps will skip"
fi

if [[ -n "$MEOW_FIXTURE_SEEDED" ]]; then SEEDED_LABEL="yes"; else SEEDED_LABEL="no"; fi
info "Step 2: Fixture dir ($FIXTURE_DIR) — seeded=${SEEDED_LABEL}"
# Seeded mode: re-create fresh each run so a half-finished previous run can't poison state.
if [[ -n "$MEOW_FIXTURE_SEEDED" && -d "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
fi
mkdir -p "$FIXTURE_DIR/proxies.d"

info "Step 3: Bring up protocol servers"
wants ss    && setup_ss
wants trojan && setup_trojan
wants vless && setup_vless
wants vmess && setup_vmess

if [[ ${#ENABLED_PROTOCOLS[@]} -eq 0 ]]; then
    fail "No protocols came up — check requested list '$MEOW_FIXTURE_PROTOCOLS' and logs under $FIXTURE_DIR"
fi

info "Step 4: Assemble Clash subscription YAML ($FIXTURE_DIR/clash.yaml)"
{
    cat <<EOF
# meow-ios fixture subscription — generated by scripts/test-e2e-ios.sh
# Enabled protocols: ${ENABLED_PROTOCOLS[*]}
mixed-port: 7890
external-controller: 127.0.0.1:9090
mode: rule
log-level: info
proxies:
EOF
    # Staged per-protocol blocks in deterministic order.
    for name in ss trojan vless vmess; do
        [[ -f "$FIXTURE_DIR/proxies.d/${name}.yaml" ]] && cat "$FIXTURE_DIR/proxies.d/${name}.yaml"
    done
    echo "proxy-groups:"
    echo "  - name: meow-auto"
    echo "    type: select"
    echo "    proxies:"
    for name in "${ENABLED_PROTOCOLS[@]}"; do
        echo "      - ${name}"
    done
    echo "      - DIRECT"
    echo "rules:"
    echo "  - MATCH,meow-auto"
} >"$FIXTURE_DIR/clash.yaml"

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
# can parse these lines directly. Only variables for enabled protocols
# are emitted so consumers can sniff presence without parsing logs.
{
    echo ""
    echo "=== Fixture ready ==="
    echo "FIXTURE_DIR=${FIXTURE_DIR}"
    echo "SUBSCRIPTION_URL=${SUBSCRIPTION_URL}"
    echo "ENABLED_PROTOCOLS=${ENABLED_PROTOCOLS[*]}"
    for name in "${ENABLED_PROTOCOLS[@]}"; do
        case "$name" in
            meow-fixture-ss)
                echo "SS_HOST=${SS_HOST}"
                echo "SS_PORT=${SS_PORT}"
                echo "SS_METHOD=${SS_METHOD}"
                echo "SS_PASSWORD=${SS_PASSWORD}"
                ;;
            meow-fixture-trojan)
                echo "TROJAN_HOST=${SS_HOST}"
                echo "TROJAN_PORT=${TROJAN_PORT}"
                echo "TROJAN_PASSWORD=${TROJAN_PASSWORD}"
                echo "TROJAN_CERT=${FIXTURE_DIR}/trojan-cert.pem"
                ;;
            meow-fixture-vless)
                echo "VLESS_HOST=${SS_HOST}"
                echo "VLESS_PORT=${VLESS_PORT}"
                echo "VLESS_UUID=${VLESS_UUID}"
                ;;
            meow-fixture-vmess)
                echo "VMESS_HOST=${SS_HOST}"
                echo "VMESS_PORT=${VMESS_PORT}"
                echo "VMESS_UUID=${VMESS_UUID}"
                ;;
        esac
    done
    echo ""
}

if [[ -z "$VPHONE_HOST" ]] && ! command -v vphone-cli &>/dev/null; then
    info "No vphone-cli — stopping after fixture setup (scaffold-only mode)"
    if [[ -n "${MEOW_FIXTURE_KEEPALIVE:-}" ]]; then
        info "Keepalive mode — Ctrl-C (interactive) or 'kill -TERM $$' to tear down"
        # Background sleep + wait so the INT/TERM trap fires and the
        # EXIT trap runs cleanup. `exec sleep` would drop the traps.
        # 2147483 ≈ 24.8 days — BSD `sleep` (macOS default) rejects
        # `infinity`, and a 24-day ceiling is fine for a dev keepalive.
        # Note on signal delivery: interactive Ctrl-C reaches the shell
        # through the controlling TTY and fires the INT trap reliably.
        # A backgrounded script (`./script &`) has SIGINT set to SIG_IGN
        # by bash per POSIX, so programmatic teardown must use SIGTERM.
        sleep 2147483 &
        KEEPALIVE_PID=$!
        wait "$KEEPALIVE_PID"
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

info "P2 SCAFFOLD COMPLETE — steps 7–9 land with T4.1/T4.2 + gate flip"
