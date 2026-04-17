# meow-ios Project Plan

**Version:** 1.0  
**Date:** 2026-04-17  
**Status:** Draft

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
- Configure signing (App Store Connect API key `5MC8U9Z7P9`, team `345Y8TX7HZ`)
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
- Install targets: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`
- Add `cbindgen` to build pipeline
- Configure `cargo build` script in `build-rust.sh`
- Verify `libmihomo_ios_ffi.a` produces on CI
- **Output:** `MihomoFfi.xcframework` in `MeowCore/Frameworks/`

#### T0.5 — Go Toolchain Setup
- Pin Go version (≥ 1.23) in `.go-version`
- Document exact Xcode/clang version requirements in `docs/BUILD.md`
- Write `build-go.sh` producing `libmihomo_arm64.a` and `libmihomo_sim_arm64.a`
- Wrap in `MihomoGo.xcframework`
- **Output:** `MihomoGo.xcframework` in `MeowCore/Frameworks/`

---

### Phase 1: Rust Core Adaptation (mihomo-ios-ffi)

#### T1.1 — Strip JNI, Export C ABI
- Copy `mihomo-android-ffi` crate to `core/rust/mihomo-ios-ffi/`
- Remove `jni` crate dependency
- Remove all `Java_*` JNI function signatures
- Export plain C functions:
  ```c
  void meow_tun_init(void);
  void meow_tun_set_home_dir(const char *dir);
  int  meow_tun_start(int fd, int socks_port, int dns_port);
  void meow_tun_stop(void);
  const char *meow_tun_last_error(void);
  ```
- Run `cbindgen` to generate `mihomo_ios_ffi.h`
- **Depends on:** T0.4
- **Output:** `mihomo_ios_ffi.h`, compiling Rust crate

#### T1.2 — iOS TUN FD Handling
- Verify `fd: c_int` (not i32 from JNI) is correct for iOS utun file descriptor
- Test reading raw packets via the fd on iOS (requires device or simulator with entitlement)
- Adjust O_NONBLOCK / `fcntl` calls if needed for iOS utun behavior
- **Depends on:** T1.1

#### T1.3 — Replace Android Logcat with os_log
- Remove `android_logger` crate
- Replace log sink with `oslog` crate or `eprintln!` redirected to `os_log`
- **Depends on:** T1.1

#### T1.4 — XCFramework Build
- Run `build-rust.sh` to produce device + simulator static libs
- `xcodebuild -create-xcframework` to produce `MihomoFfi.xcframework`
- Verify Swift can call `meow_tun_init()` from bridging header
- **Depends on:** T1.1, T1.2, T1.3

---

### Phase 2: Go Core Adaptation (mihomo-core)

#### T2.1 — Remove Android-specific Code
- Remove `jni_bridge_android.c` (Android JNI protect hook)
- Remove `android_log.go`
- Rename package from `meow-android` to `meow-ios` in go.mod
- **Depends on:** T0.5

#### T2.2 — iOS Socket Protect Hook
- Replace Android JNI protect callback with a registered C function pointer
- iOS pattern: `NEPacketTunnelProvider` does not require `protect()` calls (unlike Android); remove protect mechanism or make it a no-op
- Verify no routing loops occur on iOS (iOS Network Extension handles this differently)
- **Depends on:** T2.1

#### T2.3 — iOS Logging
- Replace `android_log.go` with `os_log` calls via cgo or stderr output
- **Depends on:** T2.1

#### T2.4 — XCFramework Build
- Run `build-go.sh` to produce device + simulator `.a` files
- Create `MihomoGo.xcframework`
- Verify Swift can call `meowEngineStart()` from bridging header
- **Depends on:** T2.1, T2.2, T2.3

---

### Phase 3: PacketTunnel Extension

#### T3.1 — PacketTunnelProvider Skeleton
- Subclass `NEPacketTunnelProvider`
- Implement `startTunnel(options:completionHandler:)` and `stopTunnel(with:completionHandler:)`
- Log lifecycle events
- **Depends on:** T0.1

#### T3.2 — Config Preparation
- On `startTunnel`: read selected profile YAML from App Group container
- Strip `subscriptions:` section; prepend `mixed-port: 7890`; write to `config.yaml` in App Group container
- Seed GeoIP/Geosite assets from app bundle to App Group container on first launch
- **Depends on:** T3.1

#### T3.3 — Go Engine Lifecycle
- On start: call `meowSetHomeDir()`, `meowStartEngine(addr:secret:)`
- Verify engine running: `meowIsRunning()`
- On stop: call `meowStopEngine()`
- Error propagation: `meowGetLastError()` → `completionHandler(error)`
- **Depends on:** T2.4, T3.2

#### T3.4 — TUN Interface Setup
- Create `NWTunnelNetworkSettings`:
  - IPv4: 172.19.0.1/30, router 172.19.0.2
  - IPv6: fdfe:dcba:9876::1/126, router fdfe:dcba:9876::2
  - DNS: 172.19.0.2 (intercepted by Rust DoH)
  - MTU: 1500
  - IPv4 default route: 0.0.0.0/0
- Call `setTunnelNetworkSettings(settings:completionHandler:)`
- **Depends on:** T3.1

#### T3.5 — Rust tun2socks Integration
- After settings applied, get TUN fd from `packetFlow` (via `NEPacketTunnelFlow.fd` or custom socket approach)
- Call `meow_tun_start(fd, 7890, 1053)`
- Note: iOS `NEPacketTunnelFlow` does not expose a raw fd directly. Two options:
  - **Option A (preferred):** Use `packetFlow.readPackets` loop and a Unix socket pair; pass one end fd to Rust
  - **Option B:** Rewrite tun reader/writer in Swift using `readPackets`/`writePackets` and proxy via a Rust channel
- Implement whichever proves feasible; document the decision in `docs/BUILD.md`
- **Depends on:** T1.4, T3.4

#### T3.6 — IPC Bridge (Extension side)
- Register CFNotificationCenter observers: `com.meow.vpn.command`
- On command notification: read intent from shared UserDefaults, dispatch to engine
- On state change: write state to shared container, post `com.meow.vpn.state`
- Traffic update timer: every 500ms, read `meowGetUploadTraffic()` + `meowGetDownloadTraffic()`, write to shared container, post `com.meow.vpn.traffic`
- **Depends on:** T0.3, T3.3

#### T3.7 — End-to-End Smoke Test
- Connect to a real proxy server via the extension
- Verify traffic flows (open Safari, load a page)
- Verify traffic counters increment
- **Depends on:** T3.3, T3.5, T3.6

---

### Phase 4: App-Side Services

#### T4.1 — SwiftData Schema
- Define `Profile` and `DailyTraffic` models (see PRD §5.1)
- Initialize `ModelContainer` in `MeowApp.swift`
- Write migration tests
- **Depends on:** T0.1

#### T4.2 — VpnManager Service
- Wrap `NETunnelProviderManager` CRUD: load, save, connect, disconnect
- Expose `@Published var state: VpnState` (idle/connecting/connected/stopping/stopped)
- Subscribe to NEVPNStatus KVO notifications
- **Depends on:** T0.1

#### T4.3 — IPC Bridge (App side)
- Post `com.meow.vpn.command` via CFNotificationCenter with intent in shared UserDefaults
- Listen for `com.meow.vpn.state` and `com.meow.vpn.traffic` notifications
- Publish received state and traffic as Combine publishers
- **Depends on:** T0.3

#### T4.4 — MihomoAPI REST Client
- `URLSession`-based client hitting `http://127.0.0.1:9090`
- Methods: `getProxies()`, `selectProxy(group:name:)`, `getConnections()`, `closeConnection(id:)`, `closeAllConnections()`, `getRules()`, `getProviders()`, `getConfigs()`, `patchConfigs(_:)`, `getMemory()`, `testDelay(proxy:url:timeout:)`
- WebSocket method: `streamLogs(level:)` → `AsyncStream<LogEntry>`
- Uses `async/await` throughout
- **Depends on:** T0.1

#### T4.5 — SubscriptionService
- `fetchSubscription(url:) async throws -> String` — download raw content
- Auto-detect Clash YAML vs node list (check for `proxies:` key)
- Node list → Clash YAML via `meowConvertSubscription()` C FFI call
- Profile CRUD backed by SwiftData
- `refreshAll()` async method
- **Depends on:** T4.1, T2.4

#### T4.6 — Traffic Accumulation
- On receiving traffic notifications, compute delta since last update
- Accumulate to today's `DailyTraffic` record in SwiftData (upsert)
- Batch writes: flush to SwiftData every 30 seconds
- **Depends on:** T4.1, T4.3

---

### Phase 5: UI Implementation

#### T5.1 — App Shell & Navigation
- `ContentView` with `TabView` (5 tabs: Home, Subscriptions, Traffic, Logs, Settings)
- iOS 26 tab bar style
- Environment objects: `VpnManager`, `MihomoAPI`, `SubscriptionService`
- **Depends on:** T4.2

#### T5.2 — Home Screen
- VPN status card with connect/disconnect button and animated state
- Traffic rate tiles (upload/download)
- Route mode picker
- Proxy groups section (fetched from `MihomoAPI.getProxies()`, filtered to selectable groups)
- Per-group proxy picker (bottom sheet or inline picker)
- "Connections" and "Rules" navigation links (visible when connected)
- Restore saved `selectedProxies` on connect
- **Depends on:** T4.2, T4.3, T4.4, T5.1

#### T5.3 — Subscriptions Screen
- List of profiles from SwiftData
- Tap to select (and write profile YAML to App Group container)
- Swipe-to-delete
- Refresh button per profile and "Refresh All"
- "+" button → add subscription sheet (name + URL fields)
- Navigation to YAML Editor
- **Depends on:** T4.1, T4.5, T5.1

#### T5.4 — Traffic Screen
- Real-time speed line chart (Swift Charts, 60-second window, upload + download series)
- Today's usage cards
- This month's usage cards (sum of DailyTraffic for current month)
- Daily history bar chart (last 7 days)
- **Depends on:** T4.3, T4.6, T5.1

#### T5.5 — Connections Screen
- Pushed from Home when connected
- Polling `MihomoAPI.getConnections()` every 1 second (Task-based timer, cancellable)
- Connection rows: host, protocol, up/down bytes, proxy chain, matched rule
- Search bar filtering
- Swipe-to-close row; "Close All" button
- **Depends on:** T4.4, T5.1

#### T5.6 — Rules Screen
- Pushed from Home when connected
- Single fetch of `MihomoAPI.getRules()` on appear, pull-to-refresh
- Rule list: type, payload, proxy
- **Depends on:** T4.4, T5.1

#### T5.7 — Logs Screen (tab)
- WebSocket stream via `MihomoAPI.streamLogs(level:)`
- Level filter picker (debug/info/warning/error)
- Auto-scroll toggle
- Search filter
- Monospace font for log lines
- **Depends on:** T4.4, T5.1

#### T5.8 — Settings Screen
- Toggle: Allow LAN, IPv6
- Picker: Log Level
- Text field: DoH Server URL
- Navigation: Diagnostics
- Version display, memory usage (polled)
- **Depends on:** T4.4, T5.1

#### T5.9 — YAML Editor Screen
- Pushed from Subscriptions
- Load `profile.yamlContent`
- `UITextView` (via `UIViewRepresentable`) with monospace font
- Save button: validate via `meowValidateConfig()`, show error if invalid, else save to SwiftData + copy to App Group container
- Revert button: restore `yamlBackup`
- **Depends on:** T4.1, T2.4, T5.3

#### T5.10 — Diagnostics Screen
- Pushed from Settings
- Three test cards: Direct TCP, Proxy HTTP, DNS Resolver
- Each with host/URL input field and "Test" button
- Results shown with latency or error
- Calls `meowTestDirectTcp()`, `meowTestProxyHttp()`, `meowTestDnsResolver()` C FFI
- **Depends on:** T2.4, T5.8

#### T5.11 — Providers Screen
- Pushed from Home (post-connection)
- Fetch `MihomoAPI.getProviders()`
- List proxy providers with their proxies and delay test button
- **Depends on:** T4.4, T5.1

---

### Phase 6: Polish & Assets

#### T6.1 — iOS 26 Liquid Glass UI Pass
- Apply `.glassEffect()` to all major cards
- Tune vibrancy, blur radius for readability
- Verify on both light and dark mode
- **Depends on:** All T5.* tasks

#### T6.2 — App Icon & Launch Screen
- Design app icon (cat + shield/VPN motif)
- All required sizes in Assets.xcassets
- Launch screen (simple logo on glass background)

#### T6.3 — Accessibility & Dynamic Type
- All text uses Dynamic Type text styles
- VoiceOver labels on all interactive controls
- Minimum tap target size 44×44pt

#### T6.4 — Localization
- English (base) localization from day 1
- Prepare `Localizable.strings` for future Simplified Chinese (matching Android's `zh_CN` strings)

---

### Phase 7: Testing

#### T7.1 — Unit Tests
- `SubscriptionService`: test Clash YAML detection, v2rayN conversion
- `DailyTraffic` accumulation logic
- `MihomoAPI`: mock URLSession, test response parsing
- `IPCBridge`: test state serialization/deserialization

#### T7.2 — Integration Tests (Extension)
- Connect + disconnect lifecycle (device required)
- Config file written correctly to App Group container
- GeoIP/Geosite seeding on first launch

#### T7.3 — UI Tests (XCUITest)
- Add subscription → appears in list
- Select profile → VPN connects
- Proxy group selection → persists after reconnect
- YAML editor save → validates and persists

#### T7.4 — Performance Tests
- Memory usage in extension during active VPN (target: < 50MB)
- Battery usage (Instruments Energy Log, 1-hour session)
- TUN throughput (iperf3 through proxy, target: ≥ 100 Mbps on WiFi)

#### T7.5 — Device Regression Matrix

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
T0.1 → T0.2, T0.3, T3.1, T4.1, T4.2, T5.1
T0.3 → T3.6, T4.3
T0.4 → T1.1
T0.5 → T2.1
T1.1 → T1.2, T1.3
T1.1+T1.2+T1.3 → T1.4
T2.1 → T2.2, T2.3
T2.1+T2.2+T2.3 → T2.4
T1.4 + T3.4 → T3.5
T2.4 + T3.2 → T3.3
T3.1 → T3.2, T3.4
T3.3 + T3.5 + T3.6 → T3.7
T4.1 + T2.4 → T4.5
T4.1 + T4.3 → T4.6
T4.2 + T5.1 → T5.2
T4.1 + T4.5 + T5.1 → T5.3
T4.3 + T4.6 + T5.1 → T5.4
T4.4 + T5.1 → T5.5, T5.6, T5.7, T5.8, T5.11
T4.1 + T2.4 + T5.3 → T5.9
T2.4 + T5.8 → T5.10
All T5.* → T6.1
T7.* after T6.*
```

---

## Milestone Summary

| Milestone | Weeks | Key Deliverable |
|-----------|-------|-----------------|
| M0: Infrastructure | 1 | Xcode project builds on CI; native toolchains ready |
| M1: Native Core | 2–3 | Traffic flows end-to-end through extension on device |
| M2: Basic UI | 4–5 | Connect/disconnect, subscriptions, settings |
| M3: Proxy & Realtime | 6–7 | Proxy selection, connections, rules, logs |
| M4: Config & Diag | 8 | YAML editor, validation, diagnostics, providers |
| M5: Traffic & Polish | 9–10 | Charts, daily history, iOS 26 UI pass |
| M6: QA & Ship | 11–12 | TestFlight beta, App Store submission |

---

## Critical Path

The **critical path** runs through the native integration:

```
T0.1 → T0.4/T0.5 → T1.*/T2.* → T3.3/T3.5 → T3.7 (smoke test) → T4.2 → T5.2 (Home) → M2
```

The TUN fd bridging problem (T3.5) is the highest-risk task. It must be prototyped and resolved in week 2 before any UI work begins.

---

## Open Questions for Team Decision

1. **TUN fd approach for iOS:** `packetFlow.readPackets` bridge to a socket pair (Option A) or rewrite tun reader in Swift using async sequences (Option B)? Option A preserves Rust code; Option B is more idiomatic iOS. Decide in M1.

2. **YAML editor:** Use `CodeEditView` Swift package (syntax highlighting) or plain UITextView? CodeEditView adds a dependency but improves UX. Decide in M4.

3. **Analytics:** Keep Firebase iOS SDK (existing Android parity) or switch to TelemetryDeck (privacy-first)? Decide before M6.

4. **Go version for gomobile vs manual cgo:** `gomobile bind` is easier but produces larger binaries; manual `go build -buildmode=c-archive` is leaner. Given existing `exports.go` C-style approach, manual build is recommended.
