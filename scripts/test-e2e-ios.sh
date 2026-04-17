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
# Status: P3 — WG/Hy2/TUIC configs-as-code layered onto the P2 scaffold
# (docs/TEST_FIXTURES.md §6). Those three are UDP-backed and remain
# end-to-end-blocked until T2.9 wires non-DNS UDP forwarding; the
# matching Swift tests carry `.disabled("blocked on T2.9")` tags so
# the flip is a one-line change. vphone drive steps (7-9) remain TODO
# behind T4.1 (deep-link handler) and T4.2 (Home Screen anchors); T2.6
# Diagnostics Panel is live so Step 9 anchors are known.
#
# Execution model:
#   The fixture servers (ssserver / trojan-go / xray / wg / hy2 / tuic)
#   spawn on the host this script runs on — the **outer runner host**
#   in the nightly pipeline. Only vphone-cli ops run inside the Tart
#   guest, reached over SSH via VPHONE_HOST. The virtual iPhone in the
#   guest reaches these fixture servers via the Tart-visible host IP
#   (the outer host's address on the `bridgeN` interface Tart bridges
#   onto), which we resolve from VPHONE_HOST. This is why the binds
#   below are 0.0.0.0 and NOT 127.0.0.1 — loopback on the host is
#   invisible to the iPhone's network stack inside the guest.
#
# Required env:
#   VPHONE_HOST           SSH target where vphone-cli and the virtual iPhone live
#                         (e.g. admin@<tart-vm-ip>). Empty = local vphone-cli,
#                         in which case FIXTURE_HOST stays on 127.0.0.1.
#   VPHONE_SOCK           Path to vm/vphone.sock on VPHONE_HOST. Default /tmp/vphone.sock.
#
# Optional env:
#   MEOW_FIXTURE_PROTOCOLS  Comma-separated protocols to stand up. Default "ss".
#                           Supported: ss, trojan, vless, vmess, wg, hy2, tuic.
#                           Unknown tokens fail; known tokens whose server binary
#                           is absent on PATH are skipped with a warning (the
#                           fixture still serves a subscription, just without
#                           that protocol's proxy entry). wg/hy2/tuic are UDP
#                           and remain end-to-end-blocked until T2.9 per
#                           docs/TEST_FIXTURES.md §4.
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
SUB_PORT="${SUB_PORT:-18080}"

# FIXTURE_HOST is the address advertised to the iPhone in the Clash
# subscription YAML — i.e. where the iPhone dials the fixture servers.
# - Local mode (no VPHONE_HOST): loopback is correct, iPhone and
#   fixtures share a kernel.
# - Tart mode (VPHONE_HOST=admin@<vm-ip>): the iPhone lives inside the
#   Tart guest and sees the outer host via Tart's bridged interface,
#   NOT via loopback. We resolve the outer-host address on the
#   interface that routes to the VM IP and advertise that instead.
tart_visible_host_ip() {
    # Parse the VM IP out of VPHONE_HOST (form: user@host)
    local vm_ip="${VPHONE_HOST#*@}"
    [[ -z "$vm_ip" || "$vm_ip" == "$VPHONE_HOST" ]] && return 1
    local iface
    iface="$(route -n get "$vm_ip" 2>/dev/null | awk '/interface: /{print $2; exit}')"
    [[ -n "$iface" ]] || return 1
    ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}'
}

if [[ -n "$VPHONE_HOST" ]]; then
    FIXTURE_HOST="$(tart_visible_host_ip || true)"
    [[ -n "$FIXTURE_HOST" ]] \
        || { echo "error: could not resolve Tart-visible host IP from VPHONE_HOST=$VPHONE_HOST — check 'route -n get <vm-ip>' output" >&2; exit 1; }
else
    FIXTURE_HOST="127.0.0.1"
fi

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
    # Seeded ports for all protocols — mirror the SS 18388 convention.
    # Kept in docs/TEST_FIXTURES.md §5 so local-dev can pin subscription
    # profiles across reruns.
    TROJAN_PORT="${TROJAN_PORT:-18443}"
    VLESS_PORT="${VLESS_PORT:-18444}"
    VMESS_PORT="${VMESS_PORT:-18445}"
    # UDP protocols (P3) — gated behind T2.9. Distinct ports from the
    # TCP block so a simultaneous full-matrix run doesn't get confused
    # if the kernel happens to permit overlap.
    WG_PORT="${WG_PORT:-18451}"
    HY2_PORT="${HY2_PORT:-18452}"
    TUIC_PORT="${TUIC_PORT:-18453}"
    TROJAN_PASSWORD="${TROJAN_PASSWORD:-meow-seeded-trojan-password}"
    VLESS_UUID="${VLESS_UUID:-00000000-0000-4000-8000-000000000001}"
    VMESS_UUID="${VMESS_UUID:-00000000-0000-4000-8000-000000000002}"
    HY2_PASSWORD="${HY2_PASSWORD:-meow-seeded-hy2-password}"
    TUIC_UUID="${TUIC_UUID:-00000000-0000-4000-8000-000000000003}"
    TUIC_PASSWORD="${TUIC_PASSWORD:-meow-seeded-tuic-password}"
else
    FIXTURE_DIR="${FIXTURE_BASE}/$(uuidgen | tr 'A-Z' 'a-z')"
    SS_PASSWORD="$(openssl rand -hex 16)"
    SS_PORT="$(alloc_port)"
    TROJAN_PORT="$(alloc_port)"
    VLESS_PORT="$(alloc_port)"
    VMESS_PORT="$(alloc_port)"
    WG_PORT="$(alloc_port)"
    HY2_PORT="$(alloc_port)"
    TUIC_PORT="$(alloc_port)"
    TROJAN_PASSWORD="$(openssl rand -hex 16)"
    VLESS_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
    VMESS_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
    HY2_PASSWORD="$(openssl rand -hex 16)"
    TUIC_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
fi
SS_ADDR="0.0.0.0:${SS_PORT}"

SSSERVER_PID=""
TROJAN_PID=""
TROJAN_FALLBACK_PID=""
XRAY_VLESS_PID=""
XRAY_VMESS_PID=""
WG_PID=""
HY2_PID=""
TUIC_PID=""
HTTPD_PID=""
KEEPALIVE_PID=""

# Track protocols that actually came up — populated by each setup function.
ENABLED_PROTOCOLS=()

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    for var in KEEPALIVE_PID HTTPD_PID TUIC_PID HY2_PID WG_PID XRAY_VMESS_PID XRAY_VLESS_PID TROJAN_PID TROJAN_FALLBACK_PID SSSERVER_PID; do
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
        ss|trojan|vless|vmess|wg|hy2|tuic) ;;
        *) fail "Unknown protocol '$p' in MEOW_FIXTURE_PROTOCOLS (supported: ss,trojan,vless,vmess,wg,hy2,tuic)" ;;
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
    server: ${FIXTURE_HOST}
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
    # This is NOT ATS / NSAllowsArbitraryLoads. App/Info.plist still sets
    # `NSAllowsArbitraryLoads: false` (secure default-deny); see TEST_FIXTURES §7.5.
    cat >"$FIXTURE_DIR/proxies.d/trojan.yaml" <<EOF
  - name: meow-fixture-trojan
    type: trojan
    server: ${FIXTURE_HOST}
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
    server: ${FIXTURE_HOST}
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
    server: ${FIXTURE_HOST}
    port: ${VMESS_PORT}
    uuid: ${VMESS_UUID}
    alterId: 0
    cipher: auto
    network: tcp
    tls: false
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-vmess)
}

# --- P3 UDP-backed protocols. All three are gated behind T2.9 (PRD v1.3)
# — non-DNS UDP forwarding isn't wired yet, so the iOS client cannot
# actually reach these servers end-to-end. The fixtures bring up the
# servers anyway (so a connect attempt would surface wire-protocol
# errors, not "no such server"), and the corresponding Swift assertions
# carry a `.disabled("blocked on T2.9")` tag per TEST_FIXTURES.md §4.
# When T2.9 ships: drop the `.disabled` attribute; no fixture change.

# tls_cert_pair: generate a one-day self-signed cert + key pair at
# $FIXTURE_DIR/<label>-cert.pem / <label>-key.pem. Shared by Hy2 and TUIC.
tls_cert_pair() {
    local label="$1"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$FIXTURE_DIR/${label}-key.pem" \
        -out "$FIXTURE_DIR/${label}-cert.pem" \
        -subj "/CN=meow-fixture.local" \
        >/dev/null 2>>"$FIXTURE_DIR/openssl.log" \
        || fail "openssl ${label} cert generation failed — see $FIXTURE_DIR/openssl.log"
}

setup_wg() {
    if ! command -v wg &>/dev/null || ! command -v wireguard-go &>/dev/null; then
        warn "wg + wireguard-go not on PATH — skipping WireGuard fixture. Install both via 'brew install wireguard-tools wireguard-go' or bake into the Tart base image (TEST_FIXTURES.md §5)."
        return 0
    fi
    # WG's "server" is just another peer; generate keypairs for both sides
    # so the client config in the Clash YAML knows the server's pubkey
    # and the server's wg0.conf knows the client's pubkey.
    wg genkey >"$FIXTURE_DIR/wg-server.priv"
    wg pubkey <"$FIXTURE_DIR/wg-server.priv" >"$FIXTURE_DIR/wg-server.pub"
    wg genkey >"$FIXTURE_DIR/wg-client.priv"
    wg pubkey <"$FIXTURE_DIR/wg-client.priv" >"$FIXTURE_DIR/wg-client.pub"
    local srv_priv srv_pub cli_priv cli_pub
    srv_priv="$(cat "$FIXTURE_DIR/wg-server.priv")"
    srv_pub="$(cat "$FIXTURE_DIR/wg-server.pub")"
    cli_priv="$(cat "$FIXTURE_DIR/wg-client.priv")"
    cli_pub="$(cat "$FIXTURE_DIR/wg-client.pub")"
    cat >"$FIXTURE_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = ${srv_priv}
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${cli_pub}
AllowedIPs = 10.13.13.2/32
EOF
    # wireguard-go on macOS needs root + TUN creation. In the Tart VM
    # the nightly runs as root so this succeeds; locally without sudo
    # it will fail and we skip — exactly the same posture as the
    # skip-if-absent branch above, so a missing WG proxy entry always
    # means "either the binary is missing or privilege is insufficient,"
    # not "the fixture is broken."
    info "Start wireguard-go (port=$WG_PORT, needs TUN + root)"
    WG_LOGFILE=1 wireguard-go -f utun-meow-fixture \
        >"$FIXTURE_DIR/wg.log" 2>&1 &
    WG_PID=$!
    sleep 0.5
    if ! kill -0 "$WG_PID" 2>/dev/null; then
        warn "wireguard-go failed to start (likely needs root for TUN) — skipping WG fixture. See $FIXTURE_DIR/wg.log"
        WG_PID=""
        return 0
    fi
    # wg setconf would go here — but wireguard-go in userspace exposes
    # its config socket path via WG_TUN_NAME_FILE. Deferred to the T2.9
    # flip when end-to-end WG actually matters; for now config-as-code
    # is the scoping goal and we already emit both sides of the keypair.
    cat >"$FIXTURE_DIR/proxies.d/wg.yaml" <<EOF
  - name: meow-fixture-wg
    type: wireguard
    server: ${FIXTURE_HOST}
    port: ${WG_PORT}
    private-key: "${cli_priv}"
    public-key: "${srv_pub}"
    ip: 10.13.13.2
    udp: true
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-wg)
}

setup_hy2() {
    if ! command -v hysteria &>/dev/null; then
        warn "hysteria not on PATH — skipping Hysteria2 fixture. Install from https://github.com/apernet/hysteria/releases (no brew formula as of 2026-04) or bake into the Tart base image (TEST_FIXTURES.md §5)."
        return 0
    fi
    tls_cert_pair hy2
    cat >"$FIXTURE_DIR/hy2.yaml" <<EOF
listen: :${HY2_PORT}
tls:
  cert: ${FIXTURE_DIR}/hy2-cert.pem
  key: ${FIXTURE_DIR}/hy2-key.pem
auth:
  type: password
  password: ${HY2_PASSWORD}
EOF
    info "Start hysteria server (port=$HY2_PORT)"
    hysteria server -c "$FIXTURE_DIR/hy2.yaml" \
        >"$FIXTURE_DIR/hy2.log" 2>&1 &
    HY2_PID=$!
    sleep 0.5
    kill -0 "$HY2_PID" 2>/dev/null \
        || fail "hysteria failed to start — see $FIXTURE_DIR/hy2.log"
    cat >"$FIXTURE_DIR/proxies.d/hy2.yaml" <<EOF
  - name: meow-fixture-hy2
    type: hysteria2
    server: ${FIXTURE_HOST}
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    sni: meow-fixture.local
    skip-cert-verify: true
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-hy2)
}

setup_tuic() {
    if ! command -v tuic-server &>/dev/null; then
        warn "tuic-server not on PATH — skipping TUIC fixture. Install from https://github.com/EAimTY/tuic/releases (no brew formula as of 2026-04) or bake into the Tart base image (TEST_FIXTURES.md §5)."
        return 0
    fi
    tls_cert_pair tuic
    cat >"$FIXTURE_DIR/tuic.json" <<EOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": {
    "${TUIC_UUID}": "${TUIC_PASSWORD}"
  },
  "certificate": "${FIXTURE_DIR}/tuic-cert.pem",
  "private_key": "${FIXTURE_DIR}/tuic-key.pem",
  "alpn": ["h3"],
  "udp_relay_mode": "native",
  "zero_rtt_handshake": false,
  "auth_timeout": "3s",
  "max_idle_time": "10s"
}
EOF
    info "Start tuic-server (port=$TUIC_PORT)"
    tuic-server -c "$FIXTURE_DIR/tuic.json" \
        >"$FIXTURE_DIR/tuic.log" 2>&1 &
    TUIC_PID=$!
    sleep 0.5
    kill -0 "$TUIC_PID" 2>/dev/null \
        || fail "tuic-server failed to start — see $FIXTURE_DIR/tuic.log"
    cat >"$FIXTURE_DIR/proxies.d/tuic.yaml" <<EOF
  - name: meow-fixture-tuic
    type: tuic
    server: ${FIXTURE_HOST}
    port: ${TUIC_PORT}
    uuid: ${TUIC_UUID}
    password: "${TUIC_PASSWORD}"
    alpn: [h3]
    sni: meow-fixture.local
    skip-cert-verify: true
    udp-relay-mode: native
EOF
    ENABLED_PROTOCOLS+=(meow-fixture-tuic)
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
wants ss     && setup_ss
wants trojan && setup_trojan
wants vless  && setup_vless
wants vmess  && setup_vmess
wants wg     && setup_wg
wants hy2    && setup_hy2
wants tuic   && setup_tuic

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
    for name in ss trojan vless vmess wg hy2 tuic; do
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

SUBSCRIPTION_URL="http://${FIXTURE_HOST}:${SUB_PORT}/clash.yaml"

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
                echo "SS_HOST=${FIXTURE_HOST}"
                echo "SS_PORT=${SS_PORT}"
                echo "SS_METHOD=${SS_METHOD}"
                echo "SS_PASSWORD=${SS_PASSWORD}"
                ;;
            meow-fixture-trojan)
                echo "TROJAN_HOST=${FIXTURE_HOST}"
                echo "TROJAN_PORT=${TROJAN_PORT}"
                echo "TROJAN_PASSWORD=${TROJAN_PASSWORD}"
                echo "TROJAN_CERT=${FIXTURE_DIR}/trojan-cert.pem"
                ;;
            meow-fixture-vless)
                echo "VLESS_HOST=${FIXTURE_HOST}"
                echo "VLESS_PORT=${VLESS_PORT}"
                echo "VLESS_UUID=${VLESS_UUID}"
                ;;
            meow-fixture-vmess)
                echo "VMESS_HOST=${FIXTURE_HOST}"
                echo "VMESS_PORT=${VMESS_PORT}"
                echo "VMESS_UUID=${VMESS_UUID}"
                ;;
            meow-fixture-wg)
                echo "WG_HOST=${FIXTURE_HOST}"
                echo "WG_PORT=${WG_PORT}"
                echo "WG_CLIENT_PRIV=${FIXTURE_DIR}/wg-client.priv"
                echo "WG_SERVER_PUB=${FIXTURE_DIR}/wg-server.pub"
                ;;
            meow-fixture-hy2)
                echo "HY2_HOST=${FIXTURE_HOST}"
                echo "HY2_PORT=${HY2_PORT}"
                echo "HY2_PASSWORD=${HY2_PASSWORD}"
                echo "HY2_CERT=${FIXTURE_DIR}/hy2-cert.pem"
                ;;
            meow-fixture-tuic)
                echo "TUIC_HOST=${FIXTURE_HOST}"
                echo "TUIC_PORT=${TUIC_PORT}"
                echo "TUIC_UUID=${TUIC_UUID}"
                echo "TUIC_PASSWORD=${TUIC_PASSWORD}"
                echo "TUIC_CERT=${FIXTURE_DIR}/tuic-cert.pem"
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

info "P3 SCAFFOLD COMPLETE — steps 7–9 land with T4.1/T4.2 + gate flip; wg/hy2/tuic assertions flip with T2.9"
