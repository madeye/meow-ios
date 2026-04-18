# meow-ios Project Plan

**Version:** 1.4  
**Date:** 2026-04-18  
**Status:** Draft  
**Changelog:**
- v1.1 — Removed Go toolchain (T0.5) and Phase 2 (Go Core). All engine functionality in single Rust `MihomoCore.xcframework` via mihomo-rust.
- v1.2 — T2.6 (Debug Diagnostics Panel) inserted as nightly E2E gate. Memory budget aligned to TEST_STRATEGY v1.2.
- v1.3 — Removed `mihomo-listener` from Rust dep list (confirmed not needed in in-process path, commit `dd3d44a`). Added T2.9 (non-DNS UDP path) as post-M1.5 backlog task with upstream dependency gate. Noted `src/subscription.rs` and `src/diagnostics.rs` as Rust-native replacements for old Go paths; T3.5 and T4.10 depend on T1.4 directly.
- v1.4 — Automated E2E scope retired per user directive 2026-04-18. T6.5 (Nightly E2E Gate, vphone-cli harness) deleted. T2.6 no longer flagged as nightly gate blocker — now feeds a manual on-device smoke owned by the user. T2.8 reframed from automated E2E smoke to manual device smoke. T6.3 UI Tests scope clarified: unit-level UI only, not full-tunnel. M1.5 milestone row rewritten to "Manual Smoke Passes". Critical path updated — nightly gate removed. Self-hosted runner docs, `nightly.yml`, tart/vphone scripts, LocalE2ETests target all queued for deletion in a separate QA-led audit PR.

---

## Overview

This plan translates the PRD milestones into a concrete, dependency-ordered task breakdown for the development team.

---

## Task Breakdown

### Phase 0: Project Infrastructure

#### T0.1 — Xcode Project Scaffold
- Create `meow-ios.xcodeproj` with two targets: `meow-ios` (app) and `PacketTunnel` (network extension)
- Configure minimum deployment target: iOS 26.0
- Set up App Group `group.io.github.madeye.meow` on both targets
- Add entitlements: `com.apple.developer.networking.networkextension` (`packet-tunnel-provider`)
- Configure signing (App Store Connect API key `<ASC_KEY_ID>`, team `<TEAM_ID>`)
- **Output:** Buildable Xcode project, both targets compile with empty implementations

#### T0.2 — CI/CD Pipeline
- GitHub Actions workflow: build app + extension on every push to `main`
- Steps: `xcodebuild build -scheme meow-ios -destination generic/platform=iOS`
- Separate step for simulator build
- Cache derived data and Swift package resolution
- **Depends on:** T0.1
- **Output:** Green CI badge on first push

#### T0.3 — Swift Package Structure
- Create `MeowShared` Swift package (consumed by both app and extension targets)
- Modules: `MeowModels` (data types), `MeowIPC` (shared notification keys + container helpers)
- **Depends on:** T0.1
- **Output:** Package resolves and imports successfully in both targets

#### T0.4 — Rust Toolchain Setup
- Install Rust targets: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`
- Add `cbindgen` to build pipeline
- Add mihomo-rust as git submodule at `core/rust/vendor/mihomo-rust`
- Scaffold `mihomo-ios-ffi` Cargo workspace; add mihomo-rust crates as dependencies (excluding `mihomo-listener` — not needed in in-process path)
- Write `build-rust.sh`: compile → lipo simulator fat binary → `xcodebuild -create-xcframework`
- Verify `MihomoCore.xcframework` produces on CI and Swift can import the bridging header
- **Output:** `MihomoCore.xcframework` in `MeowCore/Frameworks/`

---

### Phase 1: Rust Core (mihomo-ios-ffi + mihomo-rust)

#### T1.1 — Strip JNI, Wire mihomo-rust as Engine Backend
- Copy `mihomo-android-ffi` crate to `core/rust/mihomo-ios-ffi/`
- Remove `jni` crate and all `Java_*` JNI function signatures
- Add mihomo-rust workspace crates as Cargo dependencies: `mihomo-common`, `mihomo-proxy`, `mihomo-rules`, `mihomo-dns`, `mihomo-tunnel`, `mihomo-config`, `mihomo-api`
- Note: `mihomo-listener` is **not** included — no loopback listener needed in the in-process path
- Implement `engine.rs` wrapping mihomo-rust startup: `meow_engine_set_home_dir()`, `meow_engine_start()`, `meow_engine_stop()`, `meow_engine_is_running()`, `meow_engine_get_traffic()`
- Implement `src/subscription.rs`: node list → Clash YAML conversion using `mihomo-config` crate (replaces Go `convert.go`)
- Implement `src/diagnostics.rs`: direct TCP test, proxy HTTP test, DNS resolver test (replaces Go `diagnostics.go`)
- Export full C ABI (see PRD §2.4); run `cbindgen` to generate `mihomo_core.h`
- **Depends on:** T0.4
- **Output:** `mihomo_core.h`, compiling `mihomo-ios-ffi` crate

#### T1.2 — In-Process tun2socks ↔ Engine Channel (TCP)
- Wire tun2socks TCP handler to `mihomo_tunnel::tcp::handle_tcp()` via in-process Tokio channel
- Replaces Android SOCKS5 loopback; tun2socks passes `Box<dyn AsyncRead+AsyncWrite>` streams directly
- Verify no routing loops (iOS NetworkExtension handles socket protection automatically)
- **Note:** UDP non-DNS forwarding via `mihomo_tunnel::udp::handle_udp()` is **deferred to T2.9** pending upstream API maturity
- **Depends on:** T1.1

#### T1.3 — iOS TUN FD Handling & Logging
- Verify `fd: c_int` for iOS utun; handle 4-byte AF family prefix on iOS utun packets
- Adjust `O_NONBLOCK` / `fcntl` calls for iOS utun behavior
- Replace `android_logger` crate with `oslog` crate (routes to Console.app)
- **Depends on:** T1.1

#### T1.4 — XCFramework Build
- Run `build-rust.sh` to produce device + simulator static libs
- Run `cbindgen` to emit `MeowCore/include/mihomo_core.h`
- `xcodebuild -create-xcframework` to produce `MihomoCore.xcframework`
- CI gate: fail build if stripped xcframework > 8 MB (TEST_STRATEGY v1.2)
- Verify Swift can call `meow_engine_start()` from bridging header
- **Depends on:** T1.1, T1.2, T1.3

---

### Phase 2: PacketTunnel Extension

#### T2.1 — PacketTunnelProvider Skeleton
- Subclass `NEPacketTunnelProvider`
- Implement `startTunnel(options:completionHandler:)` and `stopTunnel(with:completionHandler:)`
- Log lifecycle events
- **Depends on:** T0.1

#### T2.2 — Config Preparation
- On `startTunnel`: read selected profile YAML from App Group container
- Strip `subscriptions:` section; prepend `mixed-port: 7890`; write to `config.yaml` in App Group container
- Seed GeoIP/Geosite assets from app bundle to App Group container on first launch
- **Depends on:** T2.1

#### T2.3 — Rust Engine Lifecycle
- On start: call `meow_engine_set_home_dir()`, `meow_engine_start(config_path, api_addr, secret)`
- Verify engine running: `meow_engine_is_running()`
- On stop: call `meow_engine_stop()`
- Error propagation: `meow_engine_last_error()` → `completionHandler(error)`
- **Depends on:** T1.4, T2.2

#### T2.4 — TUN Interface Setup
- Create `NWTunnelNetworkSettings`:
  - IPv4: 172.19.0.1/30, router 172.19.0.2
  - IPv6: fdfe:dcba:9876::1/126, router fdfe:dcba:9876::2
  - DNS: 172.19.0.2 (intercepted by Rust DoH)
  - MTU: 1500
  - IPv4 default route: 0.0.0.0/0
- Call `setTunnelNetworkSettings(settings:completionHandler:)`
- **Depends on:** T2.1

#### T2.5 — tun2socks Integration
- iOS `NEPacketTunnelFlow` does not expose a raw fd. Approach:
  - Create a Unix socket pair; pass one fd to `meow_tun_start()`
  - Swift reads packets via `packetFlow.readPackets()` loop and writes raw IP bytes into the socket
  - Rust reads from the other end; writes outbound packets back; Swift drains and calls `packetFlow.writePackets()`
- Call `meow_tun_start(fd, 0, 0)` (socks/dns ports unused: engine is in-process)
- Document socket-pair approach in `docs/BUILD.md`
- **Depends on:** T1.4, T2.4

#### T2.6 — Debug Diagnostics Panel  ⚑ **MANUAL SMOKE SURFACE**
- Implement an in-extension diagnostics surface, visible only when `MEOW_DEBUG=1` launch argument is set (or Settings → triple-tap version label, debug builds only)
- Implemented as `DiagnosticsPanel.swift` — a `UIViewController` (not SwiftUI) for pixel-stable label positions
- The panel runs 5 checks in sequence and renders each as a stable `UILabel` (see PRD §4.4 for exact format contract)
- **The 5 checks:**
  1. `TUN_EXISTS` — `meow_engine_is_running()` == 1 AND utun interface active
  2. `DNS_OK` — resolve `apple.com` via 172.19.0.2:53; expect ≥1 A record within 3 s
  3. `TCP_PROXY_OK` — TCP connect to `connectivitycheck.gstatic.com:443` through proxy within 5 s
  4. `HTTP_204_OK` — HTTP GET `http://connectivitycheck.gstatic.com/generate_204` returns 204
  5. `MEM_OK` — extension resident memory ≤ 14 MB; FAIL if ≥ 15 MB
- Each `UILabel` has `accessibilityIdentifier` = `CHECK_NAME` for unit-level UI test anchoring + VoiceOver
- **Blocks:** T2.8 (manual device smoke)
- **Depends on:** T2.3, T2.5

#### T2.7 — IPC Bridge (Extension side)
- Register CFNotificationCenter observers: `com.meow.vpn.command`
- On command notification: read intent from shared UserDefaults, dispatch to engine
- On state change: write state to shared container, post `com.meow.vpn.state`
- Traffic update timer: every 500ms, call `meow_engine_get_traffic(&upload, &download)`, write to shared container, post `com.meow.vpn.traffic`
- **Depends on:** T0.3, T2.3

#### T2.8 — Manual Device Smoke (user-owned)
- User runs the app on their iPhone (iOS 26 real device), connects to a real proxy server via the extension, and verifies:
  - TCP traffic flows (open Safari, load a page)
  - Traffic counters increment
  - Debug Diagnostics Panel (`MEOW_DEBUG=1` launch arg) shows all 5 checks as `PASS`
- **Owner:** user (per v1.4 directive — no automated harness reproduces this)
- **Note:** WireGuard/QUIC tests are deferred (non-DNS UDP not wired until T2.9)
- **Depends on:** T2.3, T2.5, T2.6, T2.7

#### T2.9 — Non-DNS UDP Path (Backlog)  ⚑ **POST-M1.5 / MVP GAP**
- Wire netstack-smoltcp UDP socket surface → `mihomo_tunnel::udp::handle_udp()`
- **Prerequisite gate:** check mihomo-rust upstream for UDP reverse-pump API maturity; confirm `mihomo_tunnel::udp::handle_udp` signature is stable before starting
- Also verify netstack-smoltcp UDP socket surface (bind, recv_from, send_to async API)
- Fixes: WireGuard tunnels (currently broken), QUIC/HTTP3 (currently degrades to TCP HTTP/2), UDP-only apps
- **Decision (v1.3):** Known limitation for M0→M1; disclose in release notes; patch in M1 (Milestone 5). TCP + DoH covers ~99% of user-observable iOS traffic; QUIC-heavy sites degrade gracefully.
- **Depends on:** T1.2, upstream mihomo-rust UDP API stability
- **Target milestone:** M5 (Weeks 9–10)

---

### Phase 3: App-Side Services

#### T3.1 — SwiftData Schema
- Define `Profile` and `DailyTraffic` models (see PRD §5.1)
- Initialize `ModelContainer` in `MeowApp.swift`
- Write migration tests
- **Depends on:** T0.1

#### T3.2 — VpnManager Service
- Wrap `NETunnelProviderManager` CRUD: load, save, connect, disconnect
- Expose `@Published var state: VpnState` (idle/connecting/connected/stopping/stopped)
- Subscribe to NEVPNStatus KVO notifications
- **Depends on:** T0.1

#### T3.3 — IPC Bridge (App side)
- Post `com.meow.vpn.command` via CFNotificationCenter with intent in shared UserDefaults
- Listen for `com.meow.vpn.state` and `com.meow.vpn.traffic` notifications
- Publish received state and traffic as Combine publishers
- **Depends on:** T0.3

#### T3.4 — MihomoAPI REST Client
- `URLSession`-based client hitting `http://127.0.0.1:9090`
- Methods: `getProxies()`, `selectProxy(group:name:)`, `getConnections()`, `closeConnection(id:)`, `closeAllConnections()`, `getRules()`, `getProviders()`, `getConfigs()`, `patchConfigs(_:)`, `getMemory()`, `testDelay(proxy:url:timeout:)`
- WebSocket method: `streamLogs(level:)` → `AsyncStream<LogEntry>`
- Uses `async/await` throughout
- **Depends on:** T0.1

#### T3.5 — SubscriptionService
- `fetchSubscription(url:) async throws -> String` — download raw content
- Auto-detect Clash YAML vs node list (check for `proxies:` key)
- Node list → Clash YAML via `meow_engine_convert_subscription()` C FFI (backed by `src/subscription.rs` in Rust)
- Profile CRUD backed by SwiftData
- `refreshAll()` async method
- **Depends on:** T3.1, T1.4

#### T3.6 — Traffic Accumulation
- On receiving traffic notifications, compute delta since last update
- Accumulate to today's `DailyTraffic` record in SwiftData (upsert)
- Batch writes: flush to SwiftData every 30 seconds
- **Depends on:** T3.1, T3.3

---

### Phase 4: UI Implementation

#### T4.1 — App Shell & Navigation
- `ContentView` with `TabView` (5 tabs: Home, Subscriptions, Traffic, Logs, Settings)
- iOS 26 tab bar style
- Environment objects: `VpnManager`, `MihomoAPI`, `SubscriptionService`
- **Depends on:** T3.2

#### T4.2 — Home Screen
- VPN status card with connect/disconnect button and animated state
- Traffic rate tiles (upload/download)
- Route mode picker
- Proxy groups section (fetched from `MihomoAPI.getProxies()`, filtered to selectable groups)
- Per-group proxy picker (bottom sheet or inline picker)
- "Connections" and "Rules" navigation links (visible when connected)
- Restore saved `selectedProxies` on connect
- **Depends on:** T3.2, T3.3, T3.4, T4.1

#### T4.3 — Subscriptions Screen
- List of profiles from SwiftData
- Tap to select (and write profile YAML to App Group container)
- Swipe-to-delete
- Refresh button per profile and "Refresh All"
- "+" button → add subscription sheet (name + URL fields)
- Navigation to YAML Editor
- **Depends on:** T3.1, T3.5, T4.1

#### T4.4 — Traffic Screen
- Real-time speed line chart (Swift Charts, 60-second window, upload + download series)
- Today's usage cards
- This month's usage cards (sum of DailyTraffic for current month)
- Daily history bar chart (last 7 days)
- **Depends on:** T3.3, T3.6, T4.1

#### T4.5 — Connections Screen
- Pushed from Home when connected
- Polling `MihomoAPI.getConnections()` every 1 second (Task-based timer, cancellable)
- Connection rows: host, protocol, up/down bytes, proxy chain, matched rule
- Search bar filtering
- Swipe-to-close row; "Close All" button
- **Depends on:** T3.4, T4.1

#### T4.6 — Rules Screen
- Pushed from Home when connected
- Single fetch of `MihomoAPI.getRules()` on appear, pull-to-refresh
- Rule list: type, payload, proxy
- **Depends on:** T3.4, T4.1

#### T4.7 — Logs Screen (tab)
- WebSocket stream via `MihomoAPI.streamLogs(level:)`
- Level filter picker (debug/info/warning/error)
- Auto-scroll toggle
- Search filter
- Monospace font for log lines
- **Depends on:** T3.4, T4.1

#### T4.8 — Settings Screen
- Toggle: Allow LAN, IPv6
- Picker: Log Level
- Text field: DoH Server URL
- Navigation: User-Facing Diagnostics
- Version display, memory usage (polled)
- Triple-tap version label activates Debug Diagnostics Panel (T2.6) in debug builds
- **Depends on:** T3.4, T4.1

#### T4.9 — YAML Editor Screen
- Pushed from Subscriptions
- Load `profile.yamlContent`
- `UITextView` (via `UIViewRepresentable`) with monospace font
- Save button: validate via `meow_engine_validate_config()` C FFI, show error if invalid, else save to SwiftData + copy to App Group container
- Revert button: restore `yamlBackup`
- **Depends on:** T3.1, T1.4, T4.3

#### T4.10 — User-Facing Diagnostics Screen
- Pushed from Settings
- Three test cards: Direct TCP, Proxy HTTP, DNS Resolver (user-supplied inputs)
- Each with host/URL input field and "Test" button; results show latency or error
- Calls `meow_engine_test_direct_tcp()`, `meow_engine_test_proxy_http()`, `meow_engine_test_dns()` C FFI (backed by `src/diagnostics.rs` in Rust)
- Distinct from T2.6 (debug-build diagnostics for manual smoke): T4.10 is the shipping user-facing diagnostics view, always available
- **Depends on:** T1.4, T4.8

#### T4.11 — Providers Screen
- Pushed from Home (post-connection)
- Fetch `MihomoAPI.getProviders()`
- List proxy providers with their proxies and delay test button
- **Depends on:** T3.4, T4.1

---

### Phase 5: Polish & Assets

#### T5.1 — iOS 26 Liquid Glass UI Pass
- Apply `.glassEffect()` to all major cards
- Tune vibrancy, blur radius for readability
- Verify on both light and dark mode
- **Depends on:** All T4.* tasks

#### T5.2 — App Icon & Launch Screen
- Design app icon (cat + shield/VPN motif)
- All required sizes in Assets.xcassets
- Launch screen (simple logo on glass background)

#### T5.3 — Accessibility & Dynamic Type
- All text uses Dynamic Type text styles
- VoiceOver labels on all interactive controls
- Minimum tap target size 44×44pt

#### T5.4 — Localization
- English (base) localization from day 1
- Prepare `Localizable.strings` for future Simplified Chinese (matching Android's `zh_CN` strings)

---

### Phase 6: Testing

#### T6.1 — Unit Tests
- `SubscriptionService`: test Clash YAML detection, v2rayN conversion (via `meow_engine_convert_subscription` FFI mock)
- `DailyTraffic` accumulation logic
- `MihomoAPI`: mock URLSession, test response parsing
- `IPCBridge`: test state serialization/deserialization

#### T6.2 — Integration Tests (Extension)
- Connect + disconnect lifecycle (device required)
- Config file written correctly to App Group container
- GeoIP/Geosite seeding on first launch

#### T6.3 — UI Tests (XCUITest, unit-level only)
- **Scope (v1.4):** unit-level UI tests only — NO full-tunnel scenarios. "VPN connected" state is proven by T2.8 manual device smoke, not by XCUITest.
- Add subscription → appears in list
- Proxy group selection → persists after reconnect (UI-only assertion; no live tunnel)
- YAML editor save → validates and persists
- Subscription seeder + NE-error-surface UX tests: **retired with LocalE2ETests** (v1.4)

#### T6.4 — Performance Tests
- **Extension resident memory during active VPN:** target ≤ 14 MB; hard-fail at 15 MB (TEST_STRATEGY v1.2)
- **MihomoCore.xcframework stripped binary size:** ≤ 8 MB (TEST_STRATEGY v1.2); enforced in T1.4 CI step
- Battery usage (Instruments Energy Log, 1-hour session)
- TUN throughput (iperf3 through proxy, target: ≥ 100 Mbps on WiFi)

> **T6.5 — Nightly E2E Gate (vphone-cli harness):** RETIRED in v1.4 per user directive 2026-04-18. Replaced by T2.8 (manual device smoke, user-owned). `nightly.yml` workflow, self-hosted tart runner, and `scripts/test-e2e-ios.sh` queued for deletion in a separate QA-led audit PR.

#### T6.6 — Device Regression Matrix

| Device | iOS Version | Notes |
|--------|-------------|-------|
| iPhone 16 Pro | iOS 26.0 | Primary test device |
| iPhone 15 | iOS 26.0 | Secondary |
| iPhone 14 | iOS 26.0 | Minimum target |
| iPad Pro M4 | iOS 26.0 | Tablet layout verification |
| iOS Simulator (arm64) | iOS 26.0 | CI smoke tests |

---

## Task Dependencies Graph

```
T0.1 → T0.2, T0.3, T2.1, T3.1, T3.2, T4.1
T0.3 → T2.7, T3.3
T0.4 → T1.1
T1.1 → T1.2, T1.3
T1.1 + T1.2 + T1.3 → T1.4
T1.4 + T2.4 → T2.5
T1.4 + T2.2 → T2.3
T2.1 → T2.2, T2.4
T2.3 + T2.5 → T2.6          ← M1.5 manual-smoke surface
T2.3 + T2.5 + T2.6 + T2.7 → T2.8 (manual device smoke, user-owned)
T1.2 + [upstream UDP API] → T2.9   ← post-M1.5 backlog
T3.1 + T1.4 → T3.5
T3.1 + T3.3 → T3.6
T3.2 + T4.1 → T4.2
T3.1 + T3.5 + T4.1 → T4.3
T3.3 + T3.6 + T4.1 → T4.4
T3.4 + T4.1 → T4.5, T4.6, T4.7, T4.8, T4.11
T3.1 + T1.4 + T4.3 → T4.9
T1.4 + T4.8 → T4.10
All T4.* → T5.1
T6.* after T5.*
```

---

## Milestone Summary

| Milestone | Weeks | Key Deliverable |
|-----------|-------|-----------------|
| M0: Infrastructure | 1 | Xcode project builds on CI; Rust toolchain + mihomo-rust submodule ready |
| M1: Native Core | 2–3 | `MihomoCore.xcframework` ≤8 MB stripped; TCP + DoH traffic flows on device; UDP gap documented |
| M1.5: Manual Smoke Passes | end of week 3 | T2.6 (Debug Diagnostics Panel) complete on device; user confirms all 5 checks `PASS` on their iPhone via T2.8 manual smoke |
| M2: Basic UI | 4–5 | Connect/disconnect, subscriptions, settings |
| M3: Proxy & Realtime | 6–7 | Proxy selection, connections, rules, logs |
| M4: Config & Diag | 8 | YAML editor, validation, user diagnostics, providers |
| M5: Traffic, UDP Patch & Polish | 9–10 | Charts, daily history, T2.9 (non-DNS UDP), iOS 26 UI pass |
| M6: QA & Ship | 11–12 | TestFlight beta, App Store submission |

---

## Critical Path

The critical path runs through the single Rust integration to the M1.5 manual-smoke checkpoint:

```
T0.1 → T0.4 → T1.1 → T1.2/T1.3 → T1.4 → T2.3/T2.5 → T2.6 (manual-smoke surface) → T2.8 (user smoke) → T3.2 → T4.2 (Home) → M2
```

Three tasks define critical-path risk:
1. **T1.2** — in-process tun2socks ↔ mihomo-rust Tokio channel wiring
2. **T2.5** — Swift `packetFlow.readPackets()` → Unix socket pair → Rust TUN reader
3. **T2.6** — Debug Diagnostics Panel; must ship end of week 3 so user can run T2.8 manual smoke before UI milestones are signed off

T2.9 (non-DNS UDP) is off the critical path — it's a known M0 limitation with a disclosed patch timeline (M5).

---

## Open Questions for Team Decision

1. **In-process channel vs SOCKS5 loopback:** if T1.2 Tokio channel proves complex, fall back to local SOCKS5 loopback socket (127.0.0.1:7890). Decide definitively before Phase 2 begins.

2. **T2.9 upstream gate:** before starting UDP wiring, file an issue against mihomo-rust to confirm `mihomo_tunnel::udp::handle_udp` signature is stable. Block T2.9 until upstream confirms.

3. **YAML editor:** `CodeEditView` Swift package (syntax highlighting) vs plain `UITextView`. Decide in M4.

4. **Analytics:** Firebase iOS SDK (Android parity) vs TelemetryDeck (privacy-first). Decide before M6.
