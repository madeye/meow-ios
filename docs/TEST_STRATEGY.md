# meow-ios Test Strategy & Quality Plan

**Version:** 1.2.1
**Date:** 2026-04-17
**Author:** QA Lead
**Status:** Draft
**Applies to:** meow-ios v1.0 (MVP — see `PRD.md` §3.1)
**Changelog:**
- v1.2.1 — Post-rebase cleanup after Dev's Rust-unification + PRD v1.3 landing: §11.1 CI pipeline collapses `build-rust`+`build-go` → single `build-core` producing `MihomoCore.xcframework`, adds explicit `size-check` job (§8.1 8 MB gate), drops `govulncheck`. §11.1 `nightly.yml` description now matches the Tart/vphone-cli flow actually in `.github/workflows/nightly.yml`. Editorial: removed the last "Go engine" / "Rust+Go bridge" references in §1/§4.1/§6.3 to align with PRD v1.3 pure-Rust architecture. No strategy changes; only stale refs corrected.
- v1.2 — Added §7 *Device-class E2E via vphone-cli in a SIP-disabled Tart VM* (replaces the earlier "tethered iPhone" nightly model). Tightened §8.1 memory budget: Extension resident ≤ 14 MB with a 15 MB hard ceiling (enforced as a ship-blocker test) to live inside the iOS NE memory limit. Tightened `MihomoCore.xcframework` stripped size budget to ≤ 8 MB. Renumbered §7–§13 → §8–§14.
- v1.1 — Aligned with PRD v1.1 (pure-Rust `MihomoCore.xcframework`, no Go toolchain). Merged Rust + Go FFI test sections into one; updated CI pipeline to drop the Go build job; updated C symbol names in stubs.

---

## 1. Objectives & Guiding Principles

The iOS port's critical surfaces — the Packet Tunnel Provider, the `MihomoCore.xcframework` C ABI bridge (pure Rust, PRD v1.1+), and the `NETunnelProviderManager` lifecycle — cannot be validated by unit tests alone. This strategy therefore layers four overlapping test tiers and treats on-device smoke tests as the authoritative signal for "does it work."

Guiding principles:

1. **Test close to the hardware.** Any test that exercises `NEPacketTunnelProvider`, FFI, or the App Group container must run on a real device or simulator — never mocked out at the boundary.
2. **Parity with Android where it matters.** The Android `test-e2e.sh` (see `/Volumes/DATA/workspace/meow-go/test-e2e.sh`) sets the bar: TUN interface up, DNS resolves, TCP/HTTP flows. We reproduce that five-check gate on iOS.
3. **Fail closed on security regressions.** Security checks (ATS, Keychain, no plaintext secrets) run on every PR — not in the release pipeline only.
4. **Performance is a first-class acceptance criterion.** Extension memory is hard-capped by iOS at ~15 MB; our budget is ≤ 14 MB PASS / ≥ 15 MB hard-fail (§8.1). A regression here is a ship-blocker, not a polish item.
5. **Shift-left for FFI.** The Swift↔C boundary into `MihomoCore.xcframework` is the highest-risk surface. Cover it with unit tests at the C ABI layer (see §3.1) before building UI on top.

---

## 2. Test Pyramid

```
                    ┌─────────────────────────┐
                    │  Manual / Device Matrix │   rare, expensive
                    │   (T7.5 regression)     │
                    └─────────────────────────┘
                 ┌─────────────────────────────────┐
                 │  End-to-End (VPN smoke tests)   │   CI nightly + pre-release
                 │  Simulator + physical device    │
                 └─────────────────────────────────┘
             ┌───────────────────────────────────────────┐
             │     UI tests (XCUITest)                   │   per-PR, tagged
             │     Flow-level: add sub, toggle, edit    │
             └───────────────────────────────────────────┘
         ┌─────────────────────────────────────────────────────┐
         │   Integration tests                                 │   per-PR
         │   NetworkExtension lifecycle, FFI, IPC, SwiftData  │
         └─────────────────────────────────────────────────────┘
     ┌─────────────────────────────────────────────────────────────┐
     │   Unit tests (XCTest + Swift Testing)                       │   per-commit
     │   ViewModels, services, parsers, FFI wrappers, crypto utils │
     └─────────────────────────────────────────────────────────────┘
```

Target distribution: **60% unit, 25% integration, 10% UI, 5% E2E/manual.** If unit tests can't cover something (because the logic lives inside the Network Extension or an FFI library), promote it to integration — do not skip coverage.

---

## 3. Unit Test Plan

**Target:** `MeowTests` bundle, linked against the main app target.

### 3.1 FFI Bridge Tests — `MihomoCore.xcframework`

Cover the Swift↔C boundary for the single pure-Rust library (PRD v1.1 dropped the Go engine). These are the thinnest, highest-value tests — they catch ABI drift the moment `mihomo-ios-ffi` is rebuilt.

Full exported surface per PRD §2.4. All exports return `int` status codes and write string output into caller-provided buffers (`dst`, `cap`).

| Subject | What to assert | Notes |
|---------|---------------|-------|
| `meow_engine_set_home_dir` | Accepts UTF-8 path; idempotent; handles empty string | Fuzz with non-ASCII |
| `meow_engine_start` | Valid config → 0; missing config → non-zero + populated `last_error` | Seed tmp config.yaml in test bundle |
| `meow_engine_is_running` | Reflects state after start/stop | |
| `meow_engine_stop` | Safe to call without prior start (no-op) | |
| `meow_engine_get_traffic` | Non-negative; monotonic within session; rebases to 0 on restart | |
| `meow_engine_validate_config` | Valid YAML → 0; malformed → non-zero with specific error; empty → error | Fixtures in `MeowTests/Fixtures/yaml/` |
| `meow_engine_convert_subscription` | v2rayN base64 nodelist → Clash YAML; buffer-too-small returns required size | Fixture `MeowTests/Fixtures/nodelist/` |
| `meow_engine_last_error` | Empty before any error; populated after forced failure; truncates cleanly at `cap` | |
| `meow_engine_version` | Returns semver string matching build | |
| `meow_test_direct_tcp` | Open port → 0; closed port → non-zero within 5s | Start a tiny TCP listener in setUp |
| `meow_test_proxy_http` | Valid URL through running engine → 200-class code | Requires engine started |
| `meow_test_dns_resolver` | Valid DoH URL → resolves; bad URL → error in <2s | |
| `meow_tun_start` | Accepts `c_int` fd; returns error if engine not running | Use a pipe fd or socketpair in tests |
| `meow_tun_stop` | Safe without start | |
| `meow_tun_last_error` | Populates on forced failure | |

**Buffer contract tests:** for every function taking `(char *dst, int cap)`, verify three cases: (a) ample capacity → full string written, null-terminated; (b) exact capacity → truncated cleanly; (c) `cap == 0` → returns required size, no write. These catch the most common FFI memory safety bugs.

**Tooling:** use Swift Testing (`@Test` macros, Swift 6+) for new tests, XCTest for tests that need `waitForExpectations` or `measure` blocks.

### 3.2 Config Parsing Tests

| Subject | Inputs |
|---------|--------|
| `SubscriptionParser.detectFormat(_:)` | Clash YAML, v2rayN base64 nodelist, mixed/unknown → enum |
| `SubscriptionParser.parseClash(_:)` | Fixture YAML with SS/Trojan/VLESS/WG/TUIC/Hysteria2 nodes, proxy-groups, rules — assert counts and names |
| `SubscriptionParser.parseClash(_:)` | Clash YAML missing `proxies:` → error; malformed indentation → error |
| `NodelistConverter.convert(_:)` | Base64(ss://...) nodelist → Clash YAML via FFI; assert resulting YAML has expected node count |
| `YamlPatcher.applyMixedPort(_:port:)` | Strips `subscriptions:` block; prepends/replaces `mixed-port:` |
| `YamlPatcher.restoreBackup(_:)` | Backup survives round-trip |

**Fixtures** (checked in under `MeowTests/Fixtures/`):
- `clash_full.yaml` — all supported protocols in one file
- `clash_minimal.yaml` — single SS node, single rule
- `nodelist_v2rayn.txt` — base64-wrapped ss:// lines (same shape as `meow-go/test-e2e.sh` step 3)
- `clash_malformed.yaml` — broken indentation
- `clash_empty.yaml` — empty proxies array

### 3.3 Data Model Tests

| Subject | Test |
|---------|------|
| `Profile` (SwiftData) | Create, fetch, update, delete round-trip |
| `Profile.isSelected` | At most one profile selected at a time (enforced via service-layer helper) |
| `Profile.selectedProxies` | Encode/decode `[String: String]` via JSON |
| `DailyTraffic` | Upsert by date string; tx/rx accumulation is monotonic |
| `DailyTraffic.total(for:)` | Month sum matches hand-computed fixture |
| Migration | v1 → v2 schema migration when model changes (test scaffolding ready even if no migrations yet) |

### 3.4 Subscription Service Tests

| Subject | Test |
|---------|------|
| `SubscriptionService.fetchSubscription(url:)` | Happy path → string body; 404 → specific error; timeout at 30s |
| `SubscriptionService.addProfile(name:url:)` | Creates `Profile`; second call with same URL rejected |
| `SubscriptionService.refresh(profile:)` | Updates `yamlContent` and `lastUpdated`; preserves `yamlBackup` on first refresh |
| `SubscriptionService.refreshAll()` | Parallel fetch; one failure doesn't poison others |
| `SubscriptionService.deleteProfile(_:)` | Removes from SwiftData; if deleted profile was selected, next profile becomes selected |

URLSession is injected via a `URLProtocol` subclass test double — not a full mock framework. See Apple's sample `URLProtocolStub` pattern.

### 3.5 REST Client Tests (`MihomoAPI`)

Use `URLProtocolStub` to inject canned responses for each endpoint:
- `GET /proxies` — parse groups and members; handle `now` field
- `PUT /proxies/{name}` — body serialization
- `GET /connections` — parse `ConnectionInfo` with large payload (1000 connections)
- `DELETE /connections/{id}` / `DELETE /connections`
- `GET /rules` — parse rule list
- `GET /providers/proxies`
- `GET /configs` / `PATCH /configs`
- `GET /memory`
- `GET /proxies/{name}/delay` — timeout returns specific error, ms on success
- `streamLogs` WebSocket — stub URLSessionWebSocketTask, assert `AsyncStream` emits parsed `LogEntry` values

### 3.6 IPC Bridge Tests

Use the simulator's `/private/var/mobile/Containers/Shared/AppGroup/…` path (or `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` in tests):
- Round-trip `TrafficSnapshot` struct through shared `UserDefaults`
- Round-trip `VpnState` through `state.json` on disk
- CFNotification post → observer callback timing (must be < 50ms in simulator)
- Command envelope serialization (start/stop/reload)

IPC tests that need the actual extension process live in the integration tier (§4.3).

### 3.7 Traffic Accumulator Tests

| Subject | Test |
|---------|------|
| `TrafficAccumulator.record(tx:rx:)` | Delta logic: second call is (current − previous), never negative |
| Counter reset (extension restart) | On reset, next delta is 0 not negative |
| Day rollover | Crossing midnight writes a new `DailyTraffic` row |
| Batched flush | 30s flush triggers exactly one SwiftData write per window |

### 3.8 Crypto / Security Utility Tests

| Subject | Test |
|---------|------|
| `KeychainStore.set(_:forKey:)` / `get(_:)` | Round-trip string + `Data`; access group shared with extension |
| `KeychainStore.delete(forKey:)` | Idempotent; returns nil after delete |
| Subscription URL validation | Reject file://, data://, javascript: schemes; accept http(s):// only |
| YAML sanitization | Reject YAML with anchors/aliases that reference external paths |

**Coverage target for unit tests: ≥75% line coverage on `App/Services/*` and `App/Models/*`, ≥90% on parsing/crypto modules.** Coverage for `Views/` is not a target — covered by UI tests.

---

## 4. Integration Test Plan

**Target:** `MeowIntegrationTests` bundle. Runs on iOS simulator in CI and on a physical device via TestFlight-internal build.

### 4.1 NetworkExtension VPN Lifecycle

| Scenario | Expected |
|----------|---------|
| First-launch install → request VPN permission | iOS prompts; user accepts → `NETunnelProviderManager` saves profile |
| `startTunnel` with valid config | State transitions: disconnected → connecting → connected within 8s |
| `startTunnel` with malformed YAML | State goes to `.reasserting` → `.disconnected` within 3s; `lastError` populated |
| `stopTunnel(with: .userInitiated)` | Clean teardown; TUN interface removed; `meow_engine_is_running() == 0` |
| App force-quit during VPN | Extension keeps running; re-launching app re-attaches to running provider |
| Extension crash mid-session | `NEVPNStatusDidChange` fires with `.disconnected`; no orphan state in shared container |
| Reconnect after sleep/wake | VPN re-establishes within 10s of network interface change |
| Airplane mode toggle | Gracefully degrades; reconnects without restart |

Implementation: use `NEVPNManager.shared().loadFromPreferences` then drive the provider and observe `NEVPNStatusDidChangeNotification`. Tests require network entitlements — cannot run on Xcode Cloud without a provisioned test runner.

### 4.2 MihomoCore (Rust) Engine Integration

These tests live in the extension target's `PacketTunnelTests` bundle (runs inside the extension process).

| Scenario | Expected |
|----------|---------|
| Load GeoIP + Geosite assets | First launch copies from bundle to App Group; second launch uses cached copy |
| `meow_engine_start` with test config | Returns 0 within 2s; `meow_engine_is_running()` → 1 |
| `meow_tun_start` + engine coexistence | Both run in the same Rust library via Tokio channels; no SOCKS5 loopback |
| REST API reachable | `GET http://127.0.0.1:9090/version` from inside extension returns `meow_engine_version()` output |
| In-process tun2socks ↔ engine channel | Packet sent into TUN fd appears on upstream proxy socket within 20ms median (no loopback hop) |
| DoH bootstrap | `meow_test_dns_resolver("https://1.1.1.1/dns-query")` returns 0 with at least one resolved IP |
| Memory footprint after 60s idle | `proc_task_info` reports < 40 MB resident — must stay well under the ~50 MB iOS ceiling |

### 4.3 IPC Between App and Extension

| Scenario | Expected |
|----------|---------|
| App posts `com.meow.vpn.command` start | Extension receives notification, begins connect within 500ms |
| Extension posts `com.meow.vpn.traffic` every 500ms | App-side observer fires at ≥ 1.8 Hz |
| Rapid command bursts (10 in 1s) | Extension dedupes; no state corruption |
| Large state payload (truncated connections snapshot) | Fits within shared UserDefaults size limit; if oversized, falls back to file |
| Shared container write during extension reading | No data races (verified via `ThreadSanitizer` build) |

### 4.4 SwiftData Integration

| Scenario | Expected |
|----------|---------|
| Profile CRUD under concurrent access (app + extension reading config) | No crashes; eventual consistency |
| 10k `DailyTraffic` rows | Monthly aggregation query < 100ms |
| SwiftData container recreated after deletion | Preserves data integrity; no orphan records |

---

## 5. UI Test Plan (XCUITest)

**Target:** `MeowUITests` bundle. Runs on iOS simulator.

UI tests use `XCUIApplication().launchArguments += ["-UITests", "-ResetState"]` to:
- Use an in-memory SwiftData store (no state leaks between tests)
- Inject a fake VPN manager that simulates connect/disconnect without requiring the extension
- Stub `MihomoAPI` responses via launch-environment URLs pointing at a local test server

### 5.1 Screen Coverage

| Screen | Tests |
|--------|-------|
| **Home** | VPN toggle (pill button) changes state text; traffic tiles update when fake counters tick; route-mode picker persists selection; proxy-group picker sheet opens, selection persists; connections/rules nav only appears when connected |
| **Subscriptions** | `+` opens sheet; submit with empty URL shows validation error; submit valid URL adds row; swipe-to-delete removes row; pull-to-refresh triggers refresh-all; tapping row navigates to YAML editor |
| **Traffic** | Speed chart renders with test data injection; today/month tiles match fixture sums; 7-day bar chart has correct bar count |
| **Connections** | List populates from stubbed `/connections`; search filters rows; swipe-to-close removes row; "Close All" empties list |
| **Rules** | List populates; pull-to-refresh triggers re-fetch |
| **Logs** | Level picker changes filter; auto-scroll toggle pins to bottom; search filters lines; mono font applied |
| **Settings** | All toggles persist across relaunch; DoH URL field validates URL format; version string matches `Bundle.main.infoDictionary["CFBundleShortVersionString"]`; memory usage display is non-empty |
| **YAML Editor** | Opens with `profile.yamlContent`; typing → dirty state → Save enabled; invalid YAML → error alert with specific message; valid save dismisses back; Revert restores `yamlBackup` |
| **Diagnostics** | Each of 3 test cards accepts input and returns result (stubbed FFI); bad inputs show errors |
| **Providers** | Lists providers; per-proxy delay test runs and displays result |

### 5.2 Navigation & Accessibility

| Test | Expected |
|------|---------|
| Tab bar switching preserves state | Switching Home → Settings → Home keeps Home scroll position |
| Deep link (once implemented) | `meow://connect` starts VPN from any tab |
| VoiceOver labels | Every interactive element has a non-empty `accessibilityLabel` |
| Dynamic Type (XL / AX5) | No clipping, no unreadable overlaps, no off-screen buttons |
| Dark mode | All screens render with correct glass vibrancy |
| iPad layout | Navigation adapts to sidebar/detail split on iPad Pro |

### 5.3 Permission Prompts

| Prompt | Handling |
|--------|---------|
| VPN configuration permission | First-run flow accepts; second run doesn't re-prompt |
| Local Network (if required for mihomo controller) | Accept flow completes |
| Notifications (Post-MVP) | — |

XCUITest `addUIInterruptionMonitor` intercepts and dismisses. If a prompt breaks the flow, the test fails with a helpful message, not a generic timeout.

---

## 6. Network Test Plan

Validates the actual packet path end-to-end. Run nightly on a physical device with a test proxy server, mirroring the Android `test-e2e.sh` structure.

### 6.1 Test Server Setup

Reuse the Android fixture generator. A helper script `scripts/test-e2e-ios.sh` brings up:
- `ssserver -s 0.0.0.0:8388 -k testpassword123 -m aes-256-gcm -U` (plain SS)
- `python3 -m http.server 8080` serving a base64 nodelist fixture
- One subscription profile seeded into the app's SwiftData store via a test-only deep link (`meow://test/seed?url=http://<host>:8080/nodelist.txt`)

The script then uses `xcrun simctl` (or `ios-deploy` for device) to install the app, trigger the VPN, and run connectivity checks.

### 6.2 Connectivity Checks (iOS Parity with Android's 5-Check Gate)

| # | Check | Method |
|---|-------|--------|
| 1 | TUN interface (utun*) up | `ifconfig \| grep utun` after connect — assert one utun interface with IPv4 assignment |
| 2 | DNS resolution through VPN | `dig @172.19.0.2 example.com +short` returns an IP |
| 3 | TCP connectivity | `nc -w 5 -zv 1.1.1.1 443` exits 0 |
| 4 | TCP connectivity (non-CF) | `nc -w 5 -zv 8.8.8.8 443` exits 0 |
| 5 | HTTP request | `curl -s -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204` returns 204 |

All five must pass. A single failure fails the nightly build.

### 6.3 Protocol Matrix

Each protocol gets its own YAML fixture and is validated by checks 3–5 above. Protocols in scope for MVP:

| Protocol | Fixture | Notes |
|----------|---------|-------|
| Shadowsocks (aes-256-gcm) | `fixtures/ss.yaml` | Baseline, must work |
| Shadowsocks (chacha20-ietf-poly1305) | `fixtures/ss-chacha.yaml` | |
| Trojan (with real cert) | `fixtures/trojan.yaml` | Trojan-go test server required |
| VLESS | `fixtures/vless.yaml` | Reality/TLS |
| VMess | `fixtures/vmess.yaml` | WS + TLS variant |
| WireGuard | `fixtures/wg.yaml` | Bundled kernel vs userspace |
| Hysteria2 | `fixtures/hy2.yaml` | UDP-based |
| TUIC | `fixtures/tuic.yaml` | UDP QUIC |

Test pass criterion per protocol: all 5 connectivity checks pass, and the mihomo-rust engine reports at least one successful connection via its REST controller `GET /connections` (127.0.0.1:9090 in-extension).

### 6.4 DNS (DoH)

| Check | Expected |
|-------|---------|
| DoH bootstrap with default `1.1.1.1` | Resolves example.com within 2s |
| DoH with custom server | `https://dns.google/dns-query` resolves |
| DoH fallback | If primary DoH unreachable, falls back to bootstrap DNS — **verify no plaintext DNS leaks** (see §9) |
| IPv6 AAAA | Resolves IPv6 addresses when IPv6 is enabled |

### 6.5 Edge Cases

| Scenario | Expected |
|----------|---------|
| Subscription URL returns 500 | UI shows error, existing profile intact |
| Subscription returns gzip-encoded body | Correctly decompressed |
| Subscription returns non-UTF-8 bytes | Error surfaced, not silent corruption |
| Proxy server unreachable during connect | Connect fails within 15s with specific error |
| Proxy server drops mid-session | `connections` count drops; reconnect on next request |
| Switching networks (WiFi → cellular) | Session recovers within 10s |
| Carrier NAT (CGNAT) | TCP works; UDP protocols may degrade — document observed behavior |

---

## 7. Device-class E2E via vphone-cli (Virtual iPhone) in a Tart VM

The E2E tier needs something that (a) runs iOS 26 builds unmodified, (b) is reproducible in CI, and (c) is cheaper than a self-hosted macOS host with a tethered iPhone on a desk. We adopt **[vphone-cli](https://github.com/Lakr233/vphone-cli)** — a virtual iPhone powered by Apple's Virtualization.framework and the PCC research VM image (NOT Xcode Simulator) — running inside a **[Tart](https://tart.run)** macOS VM. Tart gives us the SIP-disabled macOS environment vphone-cli requires; Tart images are OCI-compatible so the CI runner pulls them like container images.

This section describes the E2E automation layer. Individual connectivity assertions (the "5-check gate") live in §6.2; this section defines *how* they get driven on a virtual iPhone in CI.

### 7.1 Why vphone-cli over Xcode Simulator

The Xcode iOS Simulator cannot host a functioning `NEPacketTunnelProvider` — it ignores TUN interface bring-up, refuses to route traffic through the extension, and a significant fraction of our 5-check gate (see §6.2) is therefore unobservable in the simulator. Real-device CI worked but put a physical iPhone in the critical path (single point of failure, unattended reboots, cable drift). vphone-cli is the middle ground: a real iOS kernel, a real NetworkExtension runtime, but in a fully virtual, scriptable, disposable VM.

### 7.2 Runtime architecture

```
   ┌────────────────────────────────────────────────────────────┐
   │ GitHub Actions runner (macOS host, Apple Silicon)          │
   │  SIP: enabled (default)                                    │
   │                                                            │
   │   ┌──────────────────────────────────────────────────────┐ │
   │   │ Tart VM (macOS 15+, SIP DISABLED, AMFI bypass in ←── │ │   built once, pushed
   │   │ boot-args)                                           │ │   to ghcr.io/.../meow-e2e
   │   │                                                      │ │
   │   │   • vphone-cli installed from Homebrew tap           │ │
   │   │   • Virtualization.framework enabled                 │ │
   │   │   •  ┌────────────────────────────────────────────┐  │ │
   │   │      │ Virtual iPhone (iOS 26, arm64)             │  │ │
   │   │      │  — meow-ios.ipa installed                  │  │ │
   │   │      │  — controlled via vm/vphone.sock           │  │ │
   │   │      └────────────────────────────────────────────┘  │ │
   │   └──────────────────────────────────────────────────────┘ │
   └────────────────────────────────────────────────────────────┘
```

### 7.3 Tart VM image contents

A single base image `ghcr.io/<org>/meow-e2e-base:<macos-version>` is baked by the `e2e-image.yml` workflow on demand (monthly or on tool-version bumps) and pushed to GHCR. Contents:

- macOS 15 (minimum supported by vphone-cli per its README)
- **SIP disabled** (`csrutil disable` in recovery, persisted in NVRAM)
- AMFI bypass boot-arg set (required by vphone-cli to load the PCC research VM image — per upstream README)
- Homebrew + vphone-cli + vphone-mcp
- Xcode Command Line Tools + `ios-deploy` equivalents needed to install .ipa into the virtual iPhone
- Base iOS 26 PCC VM image pre-pulled (multi-GB; baking it in saves ~10 min per nightly run)
- fastlane, xcodegen, xcbeautify for build assist

Rebuilds are tracked by image tag; nightly runs pin to a specific digest so a Tart base change cannot silently drift E2E results.

### 7.4 Firmware variant

vphone-cli's README exposes three firmware variants: Regular, Development, and (research) PCC. We default to **Regular** — it matches what real users run in the App Store distribution path and is the strictest environment for code signing / entitlements. Development is fallback-only (used locally when iterating on a signing issue); PCC is reserved for future security research and is NOT used in CI.

### 7.5 Automation surface

vphone-cli exposes a host control socket at `vm/vphone.sock` (path-relative to the running VM). Our E2E scripts speak this socket directly (via `nc -U` or a small Swift helper). Operations we use:

| Operation | Purpose in E2E |
|-----------|----------------|
| `screenshot` | Capture PNG of current screen; OCR / pixel-diff for visual assertions |
| `tap x,y` | Drive UI flows (Connect button, list selection, picker confirm) |
| `swipe x1,y1→x2,y2` | Unlock gesture, modal dismiss, scroll through node lists |
| `keys "<text>"` | Input subscription URLs, passwords |
| `clipboard set "<text>"` | Faster than typing for long YAML snippets |
| `clipboard get` | Pull out the subscription URL after adding, verify round-trip |
| `button home` / `button power` | Return to springboard, force-background the app |

All test steps are wrapped in a thin `VPhone` Swift helper (`MeowUITests/Support/VPhone.swift`) that uses page-object method names (`home.tapConnect()`, `home.screenshot()`) rather than raw coordinates — so future iOS layout changes touch one file, not every test.

#### 7.5.1 Optional: AI-driven tests via vphone-mcp

For exploratory regression runs (weekly, not per-PR), we use **vphone-mcp** — the MCP companion to vphone-cli — to let an agent drive the UI and report unexpected states. This is not a CI gate (agent loops are not yet deterministic enough) but is a cheap way to catch layout regressions on every iOS beta.

### 7.6 Mapping the 5-check connectivity gate onto vphone-cli

The Android `test-e2e.sh` asserts five things. Here is how each maps onto vphone-cli automation:

| # | Android assertion | iOS on vphone-cli |
|---|-------------------|---------------------|
| 1 | TUN interface `tun0` is up | Install .ipa → `tap Connect` via socket → poll app `/debug/status` via App Group IPC dump (screenshot + OCR of the Home tab's "Connected" label, plus `vphone-cli exec ifconfig` if SIP-disabled shell access allows) |
| 2 | DNS resolves through tunnel | Script issues a DoH query targeting the test server and asserts the response IP matches a fixture |
| 3 | TCP reach `1.1.1.1:80` via proxy | Tap an in-app "Run diagnostics" affordance (to be added under T3.6); it invokes `meow_test_direct_tcp` via FFI and writes the result to App Group; screenshot shows PASS/FAIL |
| 4 | TCP reach `8.8.8.8:443` via proxy | Same as #3 but different endpoint |
| 5 | HTTP `generate_204` through proxy | `meow_test_proxy_http`; asserted the same way |

Checks 3–5 lean on a **test-only diagnostics panel** inside the app (behind a debug flag, stripped in Release). This keeps the virtual iPhone driver simple: the app surfaces signals, the harness screenshots/OCRs them. The alternative (injecting assertions via a private XPC into the NetworkExtension) is riskier and non-reproducible across iOS versions.

### 7.7 Script layout

- `scripts/test-e2e-ios.sh` — orchestrator. Boots Tart VM, waits for vphone-cli ready, installs .ipa, drives `VPhone` helper, collects xcresult + screenshots, tears down.
- `scripts/tart/bootstrap-e2e-vm.sh` — one-time VM build (pulled from image cache in CI).
- `MeowUITests/Support/VPhone.swift` — Swift wrapper around the `vm/vphone.sock` protocol.
- `MeowUITests/Flows/E2E5CheckGateTests.swift` — the five assertions tied 1:1 to the Android script.

### 7.8 Risks & mitigations

| Risk | Mitigation |
|------|------------|
| **Nested virtualization** — vphone-cli's README explicitly warns Virtualization.framework does not support nesting. Running vphone-cli inside a Tart VM is inherently in that nested regime. | Validate end-to-end on a scratch runner before baking the CI workflow. If nested virt is rejected by the macOS kernel, the fallback is a **dedicated SIP-disabled bare-metal host** (Mac mini M2 on-prem or Scaleway/MacStadium) running vphone-cli directly; Tart is dropped in that fallback. Either way, the test code above is unchanged — only the runner mapping differs. This decision is recorded in an ADR before M4 closes. |
| SIP-disabled hosts cannot receive macOS security updates via normal MDM | Image is rebuilt monthly from a fresh SIP-disabled install; old digests rotate out |
| vphone-cli upstream is a solo-maintainer project | Pin to a specific tag/commit; mirror the release tarball into our artifact storage so a deleted upstream release does not break CI |
| AMFI bypass + SIP disabled = the Tart VM is untrusted | Never run release signing inside the E2E Tart VM. Release flow (see §11) runs in a separate clean runner with SIP enabled. |
| iOS version drift between vphone-cli's PCC VM image and our deployment target | Bake a known-good PCC VM image into the Tart base; rebuild (and re-baseline perf benchmarks) when the deployment target changes |

### 7.9 When E2E fails in CI

On nightly failure:
1. All screenshots captured by `VPhone.screenshot()` are uploaded as artifacts
2. `vm/vphone.sock` event log (tap/swipe/key history) is uploaded
3. xcresult bundle is uploaded
4. Slack `#meow-ios-alerts` gets a link with the failing check, last screenshot, and the mapped Android parity check
5. The failure does NOT auto-block `main` (see §11.5) but opens an issue with label `e2e-flaky` for triage within 24h

---

## 8. Performance Benchmarks

All benchmarks run on iPhone 14 (minimum supported device) on iOS 26. E2E-adjacent perf (memory ceilings, connection-setup latency) is also validated on the vphone-cli virtual iPhone (§7) in nightly CI.

### 8.1 Memory

The iOS NetworkExtension process is capped at **~15 MB resident memory** by the system — exceeding it is a hard jetsam kill with no recovery. This is the single largest architectural constraint on meow-ios and the reason we moved from Go mihomo to pure-Rust mihomo (PRD v1.1). Our test targets are therefore tight, and the "ceiling" test is a ship-blocker.

| Metric | Target | Measurement |
|--------|--------|-------------|
| Extension resident memory at idle (60s post-connect) | ≤ **14 MB** | `task_info` via Instruments Allocations; ship-blocker |
| Extension peak memory under load (100 Mbps sustained, 60s) | ≤ **14.5 MB** | Instruments Allocations — any sample ≥ 15 MB fails build |
| Extension memory headroom stress test | No jetsam over 30 min at 50 Mbps + 200 concurrent connections | Instruments Allocations + `log stream` for jetsam events |
| `MihomoCore.xcframework` stripped on-disk | ≤ **8 MB** per-slice | CI gate via `size`/`stat`; revisit if core gains new protocols |
| App-side memory at idle | ≤ 80 MB | Instruments Allocations |
| Memory growth after 1h session | ≤ +0.5 MB in extension; ≤ +10 MB in app | Identify leaks via Instruments Leaks |

The 14 MB target leaves a 1 MB cushion below the ~15 MB jetsam threshold. There is intentionally no "peak target ≥ 14.5" row — anything that high is in the kill zone.

### 8.2 CPU

| Metric | Target | Measurement |
|--------|--------|-------------|
| Extension CPU at idle | < 2% single-core | Instruments Time Profiler |
| Extension CPU at 50 Mbps sustained | < 15% single-core | Instruments Time Profiler |
| App CPU while on Home screen (1Hz traffic updates) | < 3% single-core | Instruments Time Profiler |

### 8.3 Battery

| Metric | Target | Measurement |
|--------|--------|-------------|
| 1-hour idle VPN-connected session | ≤ 3% battery drain | Instruments Energy Log on unplugged device |
| 1-hour active session (10 Mbps average) | ≤ 8% battery drain | Instruments Energy Log |
| Background drain over 8h overnight idle VPN | ≤ 5% | Manual overnight test |

### 8.4 Connection Setup Latency

| Stage | Target |
|-------|--------|
| Tap Connect → `.connecting` state | ≤ 200 ms |
| `.connecting` → TUN up | ≤ 2 s |
| TUN up → first successful proxied TCP handshake | ≤ 3 s |
| **Total: tap → first byte through proxy** | **≤ 5 s** |

### 8.5 Throughput

| Metric | Target | Measurement |
|--------|--------|-------------|
| TCP throughput via SS proxy on WiFi | ≥ 100 Mbps | `iperf3` through proxy to a local server |
| TCP throughput via WireGuard | ≥ 150 Mbps | Same setup |
| TCP round-trip latency penalty vs direct | < 20 ms median on same LAN | Compare `ping` (direct) vs TCP SYN-ACK timing through proxy |

### 8.6 UI Responsiveness

| Metric | Target |
|--------|--------|
| Cold launch time (iPhone 14) | ≤ 1.5s to Home screen |
| Tab switch | ≤ 100ms render |
| 60s speed-chart render (Swift Charts) | 60 FPS sustained |
| Connections screen with 500 rows | Scroll at 60 FPS |

Benchmarks captured to `.trace` files, uploaded as CI artifacts on every nightly build, and compared against a baseline stored in `tests/perf/baseline.json`. A regression > 15% on any metric fails the build.

---

## 9. Security Checklist

Security checks are automated where possible and reviewed manually pre-release. A failing item is a **ship-blocker**, not a recommendation.

### 9.1 Credentials & Secrets

- [ ] No subscription credentials, proxy passwords, or API tokens written to `UserDefaults`, plist, or SwiftData unencrypted
- [ ] Subscription URL tokens (if any) stored in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- [ ] Keychain access group shared between app and extension (`$(AppIdentifierPrefix)group.io.github.madeye.meow`)
- [ ] No secrets in logs at any log level (static scan: `grep -rEi '(password|secret|token|key)\s*=' App/ PacketTunnel/`)
- [ ] No secrets in bundled `.plist` / `.strings` / `.yaml` fixtures
- [ ] Git-secrets pre-commit hook enforces the above on every commit

### 9.2 App Transport Security (ATS)

- [ ] `NSAppTransportSecurity` → no global `NSAllowsArbitraryLoads`
- [ ] Subscription URLs: HTTPS required by default; user-initiated HTTP allowed only with explicit warning + per-URL exception
- [ ] `NSExceptionDomains` empty in production build; only populated in debug for local test servers

### 9.3 Data Protection at Rest

- [ ] App container marked `NSFileProtectionCompleteUntilFirstUserAuthentication` (minimum)
- [ ] Sensitive files (config.yaml, state.json) marked `NSFileProtectionComplete`
- [ ] App Group container files inherit protection class from their first writer — verify via `xattr -l` on a live device
- [ ] SwiftData store uses encrypted configuration (iOS 26+ offers this; verify support)

### 9.4 Certificate Validation

- [ ] Default `URLSession` config: no `serverTrust` overrides, no pinning bypass
- [ ] REST client to `127.0.0.1:9090` uses HTTP (loopback-only, no cert needed) — document why, verify binding
- [ ] Proxy protocols (Trojan, VLESS over TLS) use system trust store; no `insecure-skip-verify` accessible in user-facing settings
- [ ] DoH client validates upstream certificates

### 9.5 Network Extension Hardening

- [ ] Extension does not read from App Group files it doesn't own
- [ ] `includedRoutes` matches the expected TUN network; no `0.0.0.0/0` in `excludedRoutes` (would defeat VPN)
- [ ] No `NEProxyServer` with hardcoded credentials
- [ ] Extension does not make outbound HTTP requests except through its own tunnel

### 9.6 Code-Level Security

- [ ] No `@_cdecl` or `@objc` functions exported from the app target that shouldn't be
- [ ] No `fatalError` or `preconditionFailure` on user-controlled input (denial of service vector)
- [ ] YAML parser configured to reject anchors/aliases targeting external resources
- [ ] Subscription URL scheme check: only `http` / `https` (reject `file://`, `javascript:`, `data:`)

### 9.7 Privacy

- [ ] `PrivacyInfo.xcprivacy` declares all required reason APIs (file timestamp, user defaults, etc.)
- [ ] No IDFA collection; no third-party SDKs at MVP (Firebase TBD — see PRD §Open Question 3)
- [ ] Analytics events (if any) do not include user URLs, subscription contents, or connection payloads

**Automated gate:** a `security-review.yml` GitHub Actions workflow runs on every PR, checking: git-secrets, ATS config, Keychain entitlements, and a custom linter scanning for forbidden patterns (`kSecAttrAccessibleAlways`, `NSAllowsArbitraryLoads`, etc.).

---

## 10. Acceptance Criteria by MVP Feature

Each MVP feature ships only when all listed criteria pass in CI and manual review.

### VPN Toggle (Connect / Disconnect)
- [ ] Tapping connect transitions Home pill through idle → connecting → connected within 5s
- [ ] First-launch consent prompt appears exactly once
- [ ] Disconnect returns state to idle within 2s; no orphan `utun` interface
- [ ] After force-quit and relaunch, app reflects real VPN state (no false "idle" when VPN is actually up)
- [ ] Network tests (§6.2) all 5 checks pass while connected

### Subscription Management
- [ ] Add subscription: URL validates as HTTP(S); fetch succeeds; profile appears in list
- [ ] Refresh: `lastUpdated` changes; `yamlBackup` preserved on first refresh; `yamlContent` is new parse
- [ ] Delete: row removed; if selected, next profile auto-selected
- [ ] Select: writing to App Group container succeeds; reconnect uses new profile
- [ ] 10 subscriptions: list scrolls smoothly; refresh-all completes in parallel

### Proxy Group Selection
- [ ] Selection persists after app restart
- [ ] Selection survives VPN reconnect
- [ ] PUT `/proxies/{group}` returns 204; UI reflects new selection immediately
- [ ] Delay test for each proxy returns value (ms) or specific error within timeout

### Traffic Statistics
- [ ] Rate tiles update at ≥ 2 Hz during active traffic
- [ ] Cumulative counters are monotonic within a session
- [ ] Today's totals match sum of daily records
- [ ] Speed chart shows a visible line within 1s of first traffic

### Traffic History
- [ ] Rolling 7-day bar chart populated from SwiftData
- [ ] Current-day bar grows as traffic accrues
- [ ] Month tile sums daily records correctly

### Connections View
- [ ] Live list polls every 1s while screen is visible; stops polling when backgrounded
- [ ] Each row shows host, protocol, bytes, proxy chain, matched rule
- [ ] Swipe-to-close issues DELETE and removes row on success
- [ ] "Close All" clears list within 2s

### Rules View
- [ ] List of rules populates from `/rules`
- [ ] Pull-to-refresh fetches fresh list
- [ ] Empty rule set displays a helpful empty-state message

### Real-time Logs
- [ ] WebSocket connects to `/logs?level=X` successfully
- [ ] Logs append in real time (latency < 500ms from emit to display)
- [ ] Level change closes old stream, opens new one
- [ ] Auto-scroll pins to bottom; toggling off preserves scroll position
- [ ] Search filter is case-insensitive, debounced

### YAML Editor
- [ ] Opens with existing content; monospace font
- [ ] Save with invalid YAML shows specific error from `meowValidateConfig`, file unchanged
- [ ] Save with valid YAML writes to SwiftData and App Group container
- [ ] Revert restores `yamlBackup`; if no backup exists, button disabled
- [ ] File sizes up to 500 KB load and save without UI jank

### DoH DNS
- [ ] Default DoH server (`1.1.1.1`) resolves queries during active VPN
- [ ] Custom DoH URL takes effect on next connect
- [ ] Bootstrap fallback works when DoH server unreachable — without leaking plaintext DNS

### Settings
- [ ] Allow LAN toggle updates config on next connect; verify LAN clients reach proxy
- [ ] IPv6 toggle enables AAAA resolution and v6 routing
- [ ] Log level change applies immediately to running engine
- [ ] DoH server: validates URL format; empty string resets to default

### App Version & Memory
- [ ] Version matches `Bundle.main.infoDictionary[CFBundleShortVersionString]`
- [ ] Memory poll shows non-zero values; formatted as "45 MB / 256 MB"

### Route Mode
- [ ] Rule / Global / Direct selections all take effect via `PATCH /configs`
- [ ] Mode persists across reconnects
- [ ] Direct mode: verify no upstream connections in `/connections` while connected

### Diagnostics
- [ ] TCP test: valid host succeeds; unreachable host fails within 5s
- [ ] Proxy HTTP test: valid URL returns status code; invalid URL errors clearly
- [ ] DNS test: resolves via configured DoH; shows resolved IPs

### Providers
- [ ] Providers list populates from `/providers/proxies`
- [ ] Per-provider delay test runs across member proxies
- [ ] Provider refresh triggers backend refresh

### Proxy Delay Test
- [ ] Single proxy: returns ms or timeout error within 10s
- [ ] Group: runs in parallel; slowest result within group timeout (15s)

### GeoIP / Geosite Assets
- [ ] Assets bundled in app; copied to App Group on first launch
- [ ] Geosite rules match correctly (verify via `/rules` showing GEOSITE entries)
- [ ] GeoIP DB loads within 500ms of engine start

---

## 11. CI/CD Pipeline Proposal

**Recommendation: GitHub Actions + fastlane.**

Rationale: Xcode Cloud is simpler but (a) limits Rust/Go cross-compilation flexibility, (b) lacks the free-tier runner hours the project will need for nightly E2E, (c) constrains us to Apple's workflow syntax. GitHub Actions with self-hosted macOS runners (for device E2E) and GitHub-hosted runners (for simulator builds) gives us the needed flexibility.

### 11.1 Workflows

#### `ci.yml` (on every push / PR)

Runners: `macos-14` (arm64, GitHub-hosted)

Jobs (parallel where possible):

1. **build-core** — checkout rust crate + `mihomo-rust` submodule, install `aarch64-apple-ios`/`aarch64-apple-ios-sim` Rust targets, run `scripts/build-rust.sh` → upload `MihomoCore.xcframework` artifact (single unified framework per PRD v1.1+)
2. **lint** — SwiftLint, SwiftFormat --dry-run, actionlint on workflow files
3. **security-scan** — git-secrets, custom scanners for `NSAllowsArbitraryLoads` / `kSecAttrAccessibleAlways`, `cargo audit` on Rust deps
4. **size-check** — fail if `MihomoCore.xcframework` (stripped, per-slice) exceeds 8 MB (§8.1)
5. **unit-test** — download `MihomoCore.xcframework`, `xcodebuild test -scheme meow-ios -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` for `MeowTests`
6. **integration-test** — simulator-based NetworkExtension lifecycle + FFI tests (subset that runs without device)
7. **ui-test** — `xcodebuild test -scheme meow-ios -destination '...'` for `MeowUITests`
8. **archive** — `xcodebuild archive` producing `.xcarchive` (no code signing in PR builds, signing only on `main`)

All jobs upload artifacts. `unit-test` + `ui-test` upload `xcresult` bundles for PR comment summaries via `xcresulttool`.

#### `nightly.yml` (cron: `0 6 * * *` UTC)

Runners: self-hosted macOS on Apple Silicon with Tart + SIP-disabled base image (§7). Bare-metal Mac mini is the nested-virt fallback (§7.8).

1. Pull/clone the SIP-disabled Tart VM (`ghcr.io/.../meow-e2e-base`) carrying `vphone-cli` and a baked virtual iPhone
2. Build `MihomoCore.xcframework` + app IPA; install inside the VM's virtual iPhone (`vphone-cli install`)
3. Start the ssserver container alongside the runner (container proxy, §14 resolution)
4. Run `scripts/test-e2e-ios.sh` — drives `vphone-cli --sock $VPHONE_SOCK` against the T2.6 in-app diagnostics panel to assert the 5-check gate (§6, §7.6)
5. Run memory benchmarks (§8.1) — resident ≤ 14 MB PASS, ≥ 15 MB hard-fail
6. Upload screenshots, `.xcresult`, and diagnostics panel OCR dumps as artifacts
7. Post Slack / email summary on failure

#### `release.yml` (on tag `v*.*.*`)

1. All `ci.yml` gates must pass
2. `fastlane build_appstore` — archives with App Store signing using `/Users/mlv/.appstoreconnect/AuthKey_5MC8U9Z7P9.p8`
3. `fastlane upload_testflight` — pushes to TestFlight external testing group
4. Tag notes generated from `git log --pretty=format:'- %s'` since previous tag
5. Manual approval gate before App Store submission via `fastlane deliver`

### 11.2 fastlane Lanes

```ruby
# Fastfile sketch
platform :ios do
  desc "Build & test on simulator"
  lane :test do
    run_tests(scheme: "meow-ios",
              devices: ["iPhone 16 Pro"],
              code_coverage: true)
  end

  desc "Archive for App Store"
  lane :build_appstore do
    build_ios_app(scheme: "meow-ios",
                  export_method: "app-store",
                  api_key_path: "~/.appstoreconnect/api_key.json")
  end

  desc "Push to TestFlight"
  lane :upload_testflight do
    upload_to_testflight(api_key_path: "~/.appstoreconnect/api_key.json",
                         skip_waiting_for_build_processing: true)
  end
end
```

ASC API key `5MC8U9Z7P9` (issuer `1200242f-e066-47cc-9ac8-b3affd0eee32`) is loaded from CI secrets — never committed to the repo.

### 11.3 Required Secrets

| Secret | Purpose |
|--------|--------|
| `APP_STORE_CONNECT_API_KEY_P8` | fastlane upload/signing |
| `APP_STORE_CONNECT_KEY_ID` | `5MC8U9Z7P9` |
| `APP_STORE_CONNECT_ISSUER_ID` | `1200242f-e066-47cc-9ac8-b3affd0eee32` |
| `MATCH_PASSWORD` | If we adopt fastlane match |
| `SLACK_WEBHOOK_URL` | Nightly build notifications |

### 11.4 Test Result Reporting

- `xcresulttool` extracts test results from `.xcresult` bundles
- PR comment with test/coverage summary via custom Action
- `XCResult → JUnit XML` conversion for GitHub's native test display
- Coverage posted to Codecov on every PR

### 11.5 Branch Protection

On `main`:
- Required checks: `lint`, `security-scan`, `unit-test`, `ui-test`
- Required reviews: 1 approver
- Nightly E2E failure pings `#meow-ios-alerts` but does not auto-block `main` (flaky real-device tests shouldn't block urgent fixes)

---

## 12. Risk-Based Test Prioritization

| Risk (from PRD §8) | Test Mitigation | Priority |
|---------------------|-----------------|----------|
| Extension memory limit (iOS NE cap ≈ 15 MB) | Performance benchmarks §8.1 run nightly on vphone-cli (§7); CI fails build if `MihomoCore.xcframework` > 8 MB stripped; fails runtime if resident > 14 MB sustained or any sample ≥ 15 MB | P0 |
| mihomo-rust protocol parity gaps vs. Go mihomo | Protocol matrix §6.3 exercises SS/Trojan/VLESS/VMess/WG/Hy2/TUIC through real test servers; missing/broken protocol = ship-blocker for that protocol | P0 |
| Apple review rejection | Static scan for ATS / privacy violations; manual pre-submission checklist | P0 |
| NetworkExtension sandbox file I/O | Integration tests §4.1 exercise only App Group paths; any direct path triggers test failure | P1 |
| TUN fd bridging (Option A vs B) | §4.2 covers chosen path; decision recorded in ADR before M1 closes | P0 |
| CFNotification latency | §4.3 asserts ≤ 500ms round-trip; fallback to polling documented | P1 |
| Rust cross-compile + cbindgen toolchain | CI builds `MihomoCore.xcframework` from scratch every PR; Rust toolchain + cbindgen versions pinned | P0 |
| smoltcp iOS packet framing | §6.2 nightly E2E on device is the authoritative signal | P0 |
| In-process Tokio channel (no loopback) correctness | §4.2 asserts packet-in-packet-out latency stays in-process (<20ms median); watch for deadlocks under load | P1 |

---

## 13. Exit Criteria for MVP Ship

All must be true before App Store submission:

- [ ] All acceptance criteria §10 pass on iPhone 14 (minimum device) and iPhone 16 Pro
- [ ] All 5 network checks §6.2 pass for SS, Trojan, VLESS, VMess, and WireGuard protocols (driven via vphone-cli per §7)
- [ ] Performance benchmarks §8 meet targets on iPhone 14, **including the 15 MB extension memory ceiling (§8.1)**
- [ ] Security checklist §9 is 100% complete
- [ ] Zero known P0/P1 bugs
- [ ] Full regression pass on device matrix (PROJECT_PLAN §T7.5)
- [ ] TestFlight beta running for ≥ 1 week with no crash reports in Xcode Organizer
- [ ] App Store Review Guidelines §5.4 (VPN) checklist reviewed and signed off

---

## 14. Open Questions

Still open:

1. **vphone-cli nested-virt viability** — the nightly E2E pipeline (§7) assumes vphone-cli runs inside a Tart VM. vphone-cli's README explicitly calls out that Virtualization.framework does not support nesting. We need to prove this works end-to-end on a scratch runner before M4. If it doesn't, fallback is a dedicated SIP-disabled Mac mini on-prem; decision and ADR by M4.
2. **Protocol fixture sources** — Trojan/WG/Hy2 need real test endpoints; do we stand up dedicated test servers, or piggyback on existing infra?

Resolved (team-lead, 2026-04-17):

- **CI runner topology** — GitHub-hosted `macos-14` for PR lanes (lint / unit / UI / archive). Nightly E2E uses a single dedicated device-farm runner slot (`[self-hosted, macOS, apple-silicon, tart]`). No second runner budgeted for M1–M4.
- **Test proxy host** — ssserver runs in a container **alongside the nightly runner** (mirrors the Android setup). The virtual iPhone reaches it via the Tart VM's bridged network; no shared test-infra box needed at MVP.
- **Swift Testing vs XCTest** — standardize on **Swift Testing** for all new unit/integration tests. XCTest is retained only where the framework forces it (XCUITest, `measure` blocks in perf tests).

---

## References

- `PRD.md` — product requirements
- `PROJECT_PLAN.md` — task breakdown, milestones
- `/Volumes/DATA/workspace/meow-go/test-e2e.sh` — Android E2E reference (5-check connectivity gate, subscription fixture generation)
- Apple: [Network Extension Programming Guide](https://developer.apple.com/documentation/networkextension)
- Apple: [Testing with Xcode](https://developer.apple.com/documentation/xcode/testing-your-apps-in-xcode)
- Apple: [App Transport Security](https://developer.apple.com/documentation/security/preventing_insecure_network_connections)
