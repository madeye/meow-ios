# Protocol Test Fixtures

**Status:** approved 2026-04-17 (team-lead) • **Author:** QA

Plan for standing up Trojan / WireGuard / Hysteria2 / SS / VLESS / VMess / TUIC test fixtures so the §6.3 protocol matrix in `TEST_STRATEGY.md` and the 5-check E2E gate in §6.2 can run deterministically in the nightly pipeline.

Answers the open question flagged in `TEST_STRATEGY.md` (§13 risks): *"Protocol fixture sources — Trojan/WG/Hy2 need real test endpoints; do we stand up dedicated test servers, or piggyback on existing infra?"* Resolution: **stand up dedicated, local, disposable, native-binary** — no live endpoints, no nested Docker.

---

## 1. Recommendation

**Run fixture servers natively via Homebrew inside the Tart VM, alongside vphone-cli.** Fall back to a lightweight container runtime (Lima or Colima, **not** Docker Desktop) only for protocols without a maintained brew formula.

### Why not Docker-compose

The fixtures live inside the Tart macOS guest (per `TEST_STRATEGY.md` §7 — vphone-cli requires SIP-disabled macOS). Docker Desktop in a macOS-in-macOS nesting is heavy, fragile under virtualization, and adds a second VM layer (Docker's Linux VM inside the Tart VM). Native Homebrew services sidestep that entirely. Every protocol in scope has either a brew formula or a single-binary release.

### Why not live endpoints

Deterministic, offline-capable, no credentials to rotate, no third-party availability risk, no data exfiltration concerns in CI logs. Team-lead pre-approved this direction.

### Why not purely synthetic responders (raw TCP echo with right SNI)

Would degrade to testing TLS SNI/ALPN negotiation and nothing protocol-specific. Trojan's password check, VLESS UUID framing, WireGuard's Noise IK handshake, Hysteria2's QUIC+auth — all of these need the real server-side protocol implementation to catch adapter regressions. Real server binaries, fake network (loopback), fake data.

---

## 2. Per-Protocol Matrix

Assessing: does a local, native server binary (or lightweight container) exercise the **actual protocol state machine**, or does it degrade to "just TLS with the right SNI"?

| Protocol | Server | Install | Exercises real protocol? | Notes |
| --- | --- | --- | --- | --- |
| **Shadowsocks** (`aes-256-gcm`, `chacha20-ietf-poly1305`) | `shadowsocks-rust` (ssserver) | `brew install shadowsocks-rust` | ✅ Yes — AEAD + salted stream framing end-to-end | Reference protocol, already used in Android `test-e2e.sh` |
| **Trojan** | `trojan-go` | `brew install trojan-go` (homebrew-core formula 0.10.6 as of 2026-04) | ✅ Yes — password auth over real TLS, fallthrough to HTTP backend on mismatch | Needs self-signed cert + the iOS client trusting it (test-bundle-scoped trust anchor, **never** `NSAllowsArbitraryLoads`). trojan-go does a startup reachability probe on its fallback `remote_addr:remote_port`; the fixture stands up a tiny loopback `http.server` on an ephemeral port just to satisfy that check. |
| **VLESS** | `xray-core` | `brew install xray` | ✅ Yes — UUID + flow framing; XTLS/Reality variants configurable | One binary covers VLESS + VMess |
| **VMess** | `xray-core` | `brew install xray` | ✅ Yes — VMess auth + WS/gRPC transport | Same binary as VLESS, different config block |
| **WireGuard** | `wireguard-go` | `brew install wireguard-go` | ✅ Yes in principle — real Noise IK handshake | **⚠️ BLOCKED by T2.9** — see §4 below |
| **Hysteria2** | `apernet/hysteria` | GitHub release binary (brew tap available but unofficial) | ✅ Yes — QUIC + auth | **⚠️ BLOCKED by T2.9** — see §4 below |
| **TUIC** | `tuic-server` | GitHub release binary | ✅ Yes — TUIC v5 over QUIC | **⚠️ BLOCKED by T2.9** — see §4 below |

None of the protocols degrade to "just TLS with the right SNI" under this plan — every server above runs the real protocol state machine, so adapter regressions in the iOS client surface as test failures, not as false positives.

---

## 3. Assertion Contract (per protocol)

Each fixture must assert at minimum:

1. **Handshake completes** — iOS client connects, server logs a successful auth event. Measured via the 5-check gate's `TCP_PROXY_OK` row (or UDP analogue once T2.9 lands).
2. **Data round-trip** — HTTP 204 fetch through the proxy returns 204 within the §6.2 budget (2 s warm, 5 s cold). `HTTP_204_OK` row.
3. **DNS through tunnel** — a DoH query via the engine resolves to a fixture IP controlled by the local responder (not the system resolver). `DNS_OK` row.
4. **Reconnect after server restart** — kill the fixture server, bring it back in <3 s; client reconnects without a full VPN restart. New row to add to §6.2; currently out of scope for the initial 5-check gate.
5. **Malformed/unauthorised error surface** — wrong password / wrong UUID / wrong pre-shared key produces a `last_error` on the client side with a parseable reason string (consumed by `DiagnosticsLabelParser`).

(1)–(3) run today against the existing 5-check gate once the fixture is up. (4)–(5) are incremental — flag whether they're in scope for M1.

---

## 4. UDP Blocker (critical flag)

**PRD v1.3 / PROJECT_PLAN.md T2.9:** non-DNS UDP forwarding is **deferred to post-M1.5**. Until T2.9 lands, the iOS client's `mihomo_tunnel::udp::handle_udp` is not wired to the netstack-smoltcp UDP socket surface.

Consequence for fixtures:
- **WireGuard** — UDP-only. Fixture can stand up, but the iOS client cannot send/receive through it. Fixture is useful only for verifying the config parser + adapter bring-up. End-to-end validation is blocked until T2.9.
- **Hysteria2** — QUIC (UDP). Same state.
- **TUIC** — QUIC (UDP). Same state.

**Recommendation:** stand up the SS/Trojan/VLESS/VMess fixtures first (M1 critical path). Stand up the WG/Hy2/TUIC fixture configs **as code** but keep the end-to-end assertions gated behind a `@Test(.disabled("blocked on T2.9"))` tag, mirroring the pattern used for the 5-check gate pre-T2.6. This codifies the intent now so the turn-on is a one-line change when T2.9 ships.

---

## 5. Tart VM Integration

The fixture orchestrator is a shell script `scripts/test-e2e-ios.sh` (already referenced in `TEST_STRATEGY.md` §7 as the Android-parity entry point; currently stub). Inside the Tart VM, the script will:

1. `brew install` (cached in the Tart base image — rebuilt quarterly per §7.3 cadence).
2. Generate per-run ephemeral credentials (Trojan passwords, VLESS UUIDs, WG keypairs) into `/tmp/meow-fixtures/<uuid>/`.
3. Fork each fixture as a background process from the orchestrator itself (`binary … &; FIXTURE_PID=$!`), track its PID in a shell variable, and register an `EXIT INT TERM` trap that reaps every tracked PID in reverse-start order and then wipes `/tmp/meow-fixtures/<uuid>/`. Fork-and-trap over `launchctl bootstrap` (speculated in v1): one script owns the whole lifecycle, no per-run LaunchAgent plist pollution of the Tart guest, and interactive Ctrl-C plus programmatic `kill -TERM` both land on the same cleanup path. Trojan's fallback-probe requirement is handled in the same style — a dedicated loopback `python3 -m http.server` on an ephemeral port is forked alongside trojan-go and reaped by the trap.
4. Serve a Clash subscription YAML via `python3 -m http.server 18080` — same port as the Android `test-e2e.sh` pattern, so local devs don't have to rediscover it. Claimed port allocation for future Tart VM conflict bookkeeping.
5. Point vphone-cli's iPhone at the subscription URL via the `meow://connect` deep link.
6. Tear down: the trap from step 3 fires (on exit, Ctrl-C, or SIGTERM), `kill -TERM`s each tracked PID, and removes `/tmp/meow-fixtures/<uuid>/`. No post-run LaunchAgent cleanup needed because no LaunchAgents were ever registered.

**Tart image rebuild ask:** base image needs `brew install shadowsocks-rust trojan-go xray wireguard-tools wireguard-go` plus the manually-downloaded `hysteria` / `tuic-server` binaries placed in `/usr/local/bin` (neither has a homebrew-core formula as of 2026-04, though apernet/hysteria has an unofficial tap). Targeted delta from current base: ~80 MB. Not a blocker; the base is already rebuilt per §7.3.

---

## 6. Phasing

| Phase | Scope | Gate |
| --- | --- | --- |
| **P1** | SS (both ciphers) fixture live, asserts 1–3 from §3, wired into `scripts/test-e2e-ios.sh`. Validates the whole fixture scaffold end-to-end with the simplest protocol. | Nightly green with SS row in the 5-check gate |
| **P2** | Trojan + VLESS + VMess fixtures. Reuses P1 scaffold; marginal cost per protocol is a config file + credential generator. | Nightly green with those four protocols |
| **P3** | WG + Hy2 + TUIC fixture configs as code, assertions disabled pending T2.9. | `@Test(.disabled("blocked on T2.9"))` tags in place |
| **P4** (post-T2.9) | Flip the P3 disabled tags. | Full §6.3 protocol matrix green in nightly |

Phases 1–3 are independent of T2.6 / T4.2 and can land before the 5-check gate itself goes live. P1–P2 would do it during Dev's next in-flight Phase 3 work; P3 is code-only and low-risk.

---

## 7. Decisions (2026-04-17)

Team-lead sign-off on the 5 questions raised in the original scoping draft:

1. **Homebrew-in-Tart over Docker** — ✅ approved. Lima/Colima fallback only if a future protocol has no native binary.
2. **Ephemeral CI creds, seeded local-dev creds, env-var selected** — ✅ approved.
3. **Reconnect (4) + error-surface (5) assertions** — ❌ deferred to M2. The 5-check gate contract is frozen (PRD §4.4) and extending to 7 checks would ripple through Dev, `DiagnosticsLabelParser`, OCR, and the XCUITest page object mid-milestone. Implement (4)+(5) as regular `MeowIntegrationTests` cases instead; revisit contract extension post-M1 signal. Tracked as an M2 scope item.
4. **Start P1 (SS fixture) now** — ✅ approved. `scripts/test-e2e-ios.sh` is fair game; Dev is not touching it for T4.2. Coordinate via DM or WIP-commit if overlap surfaces.
5. **Trojan trust anchor** — ✅ approved. Per-request `URLSession` delegate with explicit pin; trust anchor lives only in the test bundle's Info.plist (never in app/extension). `NSAllowsArbitraryLoads` remains a security-scan ship-blocker per `.github/workflows/ci.yml`.
