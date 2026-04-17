# meow-ios Product Requirements Document

**Version:** 1.0  
**Date:** 2026-04-17  
**Author:** Architecture Team  
**Status:** Draft

---

## 1. Product Overview

### 1.1 What is meow-ios?

meow-ios is a native iOS VPN/proxy client that ports the Android "meow" app to Apple platforms. It provides a full-featured proxy management experience — supporting Clash-protocol subscriptions, multi-protocol proxy servers (Shadowsocks, Trojan, VLESS, WireGuard, TUIC, Hysteria2, and more), rule-based traffic routing, and DNS-over-HTTPS — wrapped in a modern iOS 26 Liquid Glass UI.

### 1.2 Target Audience

- Privacy-conscious iOS users who need reliable, configurable proxy access
- Power users managing Clash/mihomo subscriptions with custom YAML configurations
- Technical users who need per-connection visibility, rule editing, and diagnostics

### 1.3 Value Proposition

meow-ios offers the full power of the mihomo proxy engine in a native iOS app with:
- **Zero-config subscriptions:** paste a URL, meow fetches and converts automatically
- **Transparent VPN:** all system traffic routed through the proxy without per-app configuration
- **Real-time visibility:** live connection table, traffic charts, rule matching logs
- **iOS-native UX:** SwiftUI with iOS 26 Liquid Glass design, no cross-platform compromises

---

## 2. Architecture Overview

### 2.1 Technology Stack

```
┌─────────────────────────────────────────────────────────┐
│              SwiftUI App (iOS 26, Liquid Glass)          │
│         Tab bar · Cards · Native controls · SwiftData    │
└─────────────────────┬───────────────────────────────────┘
                      │ App ↔ Extension IPC
                      │ (CFNotification + shared App Group UserDefaults/FileManager)
┌─────────────────────▼───────────────────────────────────┐
│         NetworkExtension Packet Tunnel Provider          │
│              (NEPacketTunnelProvider subclass)            │
└──────────┬──────────────────────────┬───────────────────┘
           │ C FFI (via Swift → C header)                  │
  ┌────────▼────────┐        ┌────────▼────────────────┐
  │  mihomo-ios-ffi  │        │   mihomo Go core         │
  │  (Rust, static) │        │   (Go, gomobile static)  │
  │  tun2socks       │        │   proxy engine + REST    │
  │  DoH client      │        │   controller             │
  └─────────────────┘        └─────────────────────────┘
```

### 2.2 Layer Responsibilities

| Layer | Technology | Responsibility |
|-------|-----------|----------------|
| UI | SwiftUI + iOS 26 | All screens, navigation, state presentation |
| App ↔ Extension IPC | CFNotificationCenter + App Group container | Commands (connect/disconnect) and state/traffic events |
| Packet Tunnel Provider | NEPacketTunnelProvider | VPN lifecycle, TUN fd management, per-app routing |
| Rust (mihomo-ios-ffi) | Rust, cbindgen C header | tun2socks (netstack-smoltcp), DoH forwarding |
| Go (mihomo core) | Go + cgo | mihomo proxy engine, REST controller at 127.0.0.1:9090 |
| Persistence | SwiftData | Profiles, daily traffic history |
| Preferences | UserDefaults (App Group shared) | Port, DoH server, per-app mode |

### 2.3 VPN Data Path

```
iOS Network Stack
      ↓  all IP packets captured by NEPacketTunnelProvider
TUN interface (utun*)
      ↓  raw packets fed to Rust via packetFlow.readPackets()
netstack-smoltcp (Rust)
      ↓  TCP sessions proxied via SOCKS5
Go mihomo engine  ←→  REST API (127.0.0.1:9090 inside extension)
      ↓  upstream proxy protocol (SS/Trojan/VLESS/WG/etc.)
Remote proxy server
```

### 2.4 FFI Strategy

**Swift → Rust (C bridge):**
- Rust crate (`mihomo-ios-ffi`) exports a C-compatible interface via `cbindgen`
- Headers placed in `MeowCore/include/mihomo_ios_ffi.h`
- Swift calls `startTun2Socks(fd:socksPort:dnsPort:)` etc. through the bridging header

**Swift → Go (C bridge):**
- Go package (`mihomo-core`) compiled with `CGO_ENABLED=1` and `gomobile bind` or manual `go build -buildmode=c-archive`
- Exports `meowEngineStart()`, `meowStopEngine()`, etc. as C symbols
- Header placed in `MeowCore/include/mihomo_go.h`

**No JNI — pure C ABI** shared between both native layers. Swift calls C functions directly through the Objective-C bridging header mechanism.

### 2.5 IPC Between App and Extension

iOS restricts direct process communication to/from Network Extensions. The chosen pattern:

- **Commands (App → Extension):** Write intent to shared `UserDefaults(suiteName: appGroupID)`, then post a `CFNotificationCenter.darwinNotify` named `com.meow.vpn.command`
- **State (Extension → App):** Extension writes state to shared container, posts `com.meow.vpn.state`
- **Traffic (Extension → App):** Extension writes a small traffic struct to a shared memory-mapped file (or App Group UserDefaults) at 500ms intervals, posts `com.meow.vpn.traffic`

This avoids XPC complexity while remaining within Apple's sandbox restrictions.

---

## 3. Feature Matrix

### 3.1 MVP Features

| Feature | Android Implementation | iOS Implementation | Priority |
|---------|----------------------|-------------------|----------|
| VPN toggle (connect/disconnect) | VpnService + NEVPNManager-style toggle | NEPacketTunnelProvider + NETunnelProviderManager | MVP |
| Subscription management | Room DB + SubscriptionService | SwiftData + SubscriptionService (Swift) | MVP |
| Add subscription (URL + name) | Dialog → fetch → convert | Sheet → fetch → convert | MVP |
| Refresh subscription | SubscriptionService.fetchSubscription() | Same logic in Swift | MVP |
| Delete subscription | Room DAO | SwiftData delete | MVP |
| Select active profile | DataStore.selectedProfile | @AppStorage / SwiftData | MVP |
| Proxy group selection | REST PUT /proxies/{name} | REST PUT /proxies/{name} | MVP |
| Traffic statistics (rates + totals) | EventChannel every 100ms | CFNotification + shared container | MVP |
| Traffic history (daily chart) | DailyTraffic Room entity | SwiftData DailyTraffic entity | MVP |
| Real-time connections view | Polling GET /connections | Polling GET /connections | MVP |
| Close connection | DELETE /connections/{id} | DELETE /connections/{id} | MVP |
| Rules view | GET /rules | GET /rules | MVP |
| Real-time logs | WebSocket /logs | WebSocket /logs | MVP |
| YAML config editor | Sora editor (platform view) | Native UITextView / CodeEditView | MVP |
| Validate YAML | nativeValidateConfig() | meowValidateConfig() C FFI | MVP |
| Revert YAML | yamlBackup in Room | yamlBackup in SwiftData | MVP |
| DoH DNS | Rust doh_client.rs | Same Rust module (iOS target) | MVP |
| Settings (log level, IPv6, allow LAN) | SharedPreferences | UserDefaults | MVP |
| App version display | BuildConfig.VERSION_NAME | Bundle.main.infoDictionary | MVP |
| Memory usage display | GET /memory | GET /memory | MVP |
| Route mode (rule/global/direct) | PATCH /configs | PATCH /configs | MVP |
| Diagnostics (TCP/proxy/DNS tests) | nativeTest* | meowTest* C FFI | MVP |
| Providers view | GET /providers | GET /providers | MVP |
| Proxy delay test | GET /proxies/{name}/delay | GET /proxies/{name}/delay | MVP |
| GeoIP/Geosite bundled assets | bundled in APK assets | bundled in app bundle | MVP |

### 3.2 Post-MVP Features

| Feature | Notes |
|---------|-------|
| Per-app routing | iOS NEPacketTunnelProvider does not support per-app allow/deny lists like Android VpnService. Post-MVP: explore NEAppRule (MDM only) or DNS-based routing workaround. |
| Widget (traffic display) | WidgetKit extension showing current traffic rates | 
| Siri shortcuts | "Start VPN" shortcut via AppIntents |
| iCloud sync of profiles | CloudKit integration for subscription sync across devices |
| Apple Watch companion | Glanceable VPN status + toggle |
| macOS Catalyst | Extend to Mac via Catalyst once iOS is stable |

### 3.3 Not Applicable (iOS Platform Constraints)

| Feature | Reason |
|---------|--------|
| Installed-app list for per-app proxy | iOS does not expose installed app list to third-party apps |
| App icons in per-app proxy UI | Same restriction |
| Firebase Analytics (exact parity) | Will use same Firebase iOS SDK; analytics events are functionally equivalent |

---

## 4. iOS 26 UI Design Direction

### 4.1 Design Language

meow-ios adopts **iOS 26 Liquid Glass** throughout:
- `.glassEffect()` modifier on cards and panels
- Tab bar uses the new floating glass tab bar (`.tabBarStyle(.prominent)` equivalent)
- Frosted glass navigation bars and sheets
- Adaptive dark/light appearance with vibrancy
- SF Symbols 7 iconography
- Large title navigation where appropriate

### 4.2 Navigation Structure

```
TabView (Liquid Glass tab bar)
├── Home          (house.fill)
├── Subscriptions (text.document.fill)
├── Traffic       (chart.bar.fill)
├── Logs          (list.bullet.rectangle.fill)
└── Settings      (gearshape.fill)
```

Auxiliary screens pushed from within tabs:
- Home → Connections (active sessions)
- Home → Rules
- Home → Providers
- Subscriptions → YAML Editor
- Settings → Diagnostics
- Settings → Per-App Proxy (Post-MVP)

### 4.3 Screen Designs

#### Home Screen
```
┌─────────────────────────────────────────┐
│  [Glass nav bar]  meow          [gear]  │
│                                         │
│  ┌─── Glass Card ──────────────────┐   │
│  │  ●  Connected · My Subscription │   │
│  │     [  ████  Disconnect  ████  ]│   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌── Traffic ──┐  ┌── Traffic ──┐      │
│  │ ↑ 1.2 MB/s  │  │ ↓ 3.4 MB/s │      │
│  │ Total 45 MB │  │ Total 102MB │      │
│  └─────────────┘  └─────────────┘      │
│                                         │
│  Route Mode    [Rule ▾]                 │
│                                         │
│  PROXY GROUPS                           │
│  ┌─── Glass Card ──────────────────┐   │
│  │  Proxy          [Hong Kong ▾]   │   │
│  └─────────────────────────────────┘   │
│  ┌─── Glass Card ──────────────────┐   │
│  │  Auto-Select    [node-01 ▾]     │   │
│  └─────────────────────────────────┘   │
│                                         │
│  [Connections ›]  [Rules ›]            │
└─────────────────────────────────────────┘
```

VPN toggle uses a pill-shaped button with animated glass shimmer on connect.  
Status dot: gray=idle, yellow=connecting, green=connected, red=error.

#### Subscriptions Screen
```
┌─────────────────────────────────────────┐
│  Subscriptions                    [+]   │
│                                         │
│  ┌─── Glass Card ──────────────────┐   │
│  │ ◉  My Sub           [↻] [✎] [✕]│   │
│  │    Updated 2h ago               │   │
│  └─────────────────────────────────┘   │
│  ┌─── Glass Card ──────────────────┐   │
│  │ ○  Work VPN         [↻] [✎] [✕]│   │
│  │    Updated 1d ago               │   │
│  └─────────────────────────────────┘   │
│                                         │
│  [Refresh All]                          │
└─────────────────────────────────────────┘
```

Add subscription via bottom sheet with URL + name fields.

#### Traffic Screen
```
┌─────────────────────────────────────────┐
│  Traffic                                │
│                                         │
│  ┌─── Speed Chart (Glass) ──────────┐  │
│  │  ↑↓ real-time line graph         │  │
│  │  60-second sliding window        │  │
│  └───────────────────────────────── ┘  │
│                                         │
│  ┌── Today ────┐  ┌── This Month ──┐   │
│  │  ↑ 245 MB   │  │  ↑ 12.4 GB    │   │
│  │  ↓ 1.2 GB   │  │  ↓ 45.2 GB    │   │
│  └─────────────┘  └────────────────┘   │
│                                         │
│  DAILY HISTORY                          │
│  ┌─── Bar Chart (Glass) ────────────┐  │
│  │  7-day bar chart                 │  │
│  └──────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

Charts use Swift Charts framework.

#### Connections Screen
```
┌─────────────────────────────────────────┐
│  ← Connections (47)     [Close All]    │
│  ┌─ Search ──────────────────────────┐ │
│  └───────────────────────────────────┘ │
│                                         │
│  ┌─── Glass Row ───────────────────┐   │
│  │  github.com:443    TCP          │   │
│  │  ↑ 12KB  ↓ 45KB   Proxy › node1│   │
│  │  Rule: DOMAIN-SUFFIX,github.com │   │
│  └─────────────────────────────────┘   │
│  ...                                    │
└─────────────────────────────────────────┘
```

Swipe-to-close on each row.

#### Logs Screen
```
┌─────────────────────────────────────────┐
│  Logs              [DEBUG ▾]  [🔍]     │
│                                         │
│  ┌─ Monospace log lines ─────────────┐ │
│  │ 10:23:01 [INFO]  proxy started    │ │
│  │ 10:23:02 [DEBUG] dial github.com  │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

Scrollable list with auto-scroll to bottom toggle.

#### Settings Screen
```
┌─────────────────────────────────────────┐
│  Settings                               │
│                                         │
│  GENERAL                                │
│  Allow LAN                    [toggle] │
│  IPv6                         [toggle] │
│  Log Level                   [Info ▾] │
│                                         │
│  DNS                                    │
│  DoH Server                [1.1.1.1 >] │
│                                         │
│  DIAGNOSTICS                            │
│  Network Diagnostics              [>]  │
│                                         │
│  ABOUT                                  │
│  Version                        1.0.0  │
│  Memory Usage            45MB / 256MB  │
└─────────────────────────────────────────┘
```

#### YAML Editor Screen
```
┌─────────────────────────────────────────┐
│  ← Edit Config     [Revert]   [Save]   │
│                                         │
│  ┌─ CodeEditView / UITextView ────────┐ │
│  │  mixed-port: 7890                  │ │
│  │  proxies:                          │ │
│  │    - name: node1                   │ │
│  │      type: ss                      │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

Uses `CodeEditView` (Swift package) or fallback `UITextView` with monospace font.

---

## 5. Data Model

### 5.1 SwiftData Schema

```swift
@Model
class Profile {
    var id: UUID
    var name: String
    var url: String
    var yamlContent: String
    var yamlBackup: String        // for revert
    var isSelected: Bool
    var lastUpdated: Date
    var txBytes: Int64
    var rxBytes: Int64
    var selectedProxies: String   // JSON-encoded [String: String]
}

@Model  
class DailyTraffic {
    @Attribute(.unique) var date: String   // "yyyy-MM-dd"
    var txBytes: Int64
    var rxBytes: Int64
}
```

### 5.2 UserDefaults (App Group Shared)

Key prefix: `com.meow.`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `mixedPort` | Int | 7890 | mihomo mixed-port |
| `localDnsPort` | Int | 1053 | local DNS listener |
| `dohServer` | String | "" | DoH URL override |
| `logLevel` | String | "info" | debug/info/warning/error/silent |
| `allowLan` | Bool | false | expose proxy to LAN |
| `ipv6` | Bool | false | enable IPv6 routing |
| `perAppMode` | String | "proxy" | "proxy" or "bypass" |
| `perAppPackages` | Data | [] | JSON-encoded [String] bundle IDs |

### 5.3 Shared App Group Container

App Group ID: `group.io.github.madeye.meow`

| Path | Purpose |
|------|---------|
| `config.yaml` | Active config written before connect |
| `geoip.metadb` | GeoIP database (copied from bundle on first launch) |
| `geosite.dat` | Geosite database |
| `country.mmdb` | Country database |
| `traffic.json` | Rolling traffic struct (extension writes, app reads) |
| `state.json` | Current VPN state (extension writes, app reads) |

---

## 6. Build & Integration Plan

### 6.1 Rust (mihomo-ios-ffi)

The existing Android `mihomo-android-ffi` crate is adapted:

1. Remove all JNI dependencies (`jni` crate)
2. Rename to `mihomo-ios-ffi`
3. Export a plain C ABI using `#[no_mangle] pub extern "C" fn ...`
4. Generate C header with `cbindgen`
5. Cross-compile for iOS targets:

```bash
# iOS device (arm64)
cargo build --target aarch64-apple-ios --release

# iOS simulator (arm64 + x86_64 → fat binary)
cargo build --target aarch64-apple-ios-sim --release
cargo build --target x86_64-apple-ios --release
lipo -create ... -output libmihomo_ios_ffi_sim.a
```

6. Produce `libmihomo_ios_ffi.a` (device) and `libmihomo_ios_ffi_sim.a` (simulator)
7. Wrap in XCFramework: `xcodebuild -create-xcframework ...`

**Key changes from Android:** replace `fd: jint` (i32) with `fd: c_int`; remove `VpnService` JObject parameter; remove Android logcat calls.

### 6.2 Go (mihomo core)

The existing `mihomo-core` Go package:

1. Remove Android JNI bridge (`jni_bridge_android.c`, `android_log.go`, `protect.go` Android-specific parts)
2. Add iOS socket protect hook using a registered Swift callback instead of JNI
3. Compile as static C archive:

```bash
# iOS device
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CC=$(xcrun -sdk iphoneos -find clang) \
  CGO_CFLAGS="-arch arm64 -isysroot $(xcrun -sdk iphoneos --show-sdk-path)" \
  go build -buildmode=c-archive -o libmihomo_arm64.a ./

# iOS simulator  
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 GOFLAGS="-tags=ios_simulator" \
  go build -buildmode=c-archive -o libmihomo_sim_arm64.a ./
```

4. Produce XCFramework: `MihomoGo.xcframework`

### 6.3 Xcode Project Structure

```
meow-ios/
├── meow-ios.xcodeproj
├── App/                          # Main app target
│   ├── MeowApp.swift
│   ├── Views/
│   │   ├── HomeView.swift
│   │   ├── SubscriptionsView.swift
│   │   ├── TrafficView.swift
│   │   ├── LogsView.swift
│   │   ├── SettingsView.swift
│   │   ├── ConnectionsView.swift
│   │   ├── RulesView.swift
│   │   ├── ProvidersView.swift
│   │   ├── DiagnosticsView.swift
│   │   └── YamlEditorView.swift
│   ├── ViewModels/
│   │   ├── HomeViewModel.swift
│   │   ├── SubscriptionsViewModel.swift
│   │   ├── TrafficViewModel.swift
│   │   └── ...
│   ├── Services/
│   │   ├── VpnManager.swift       # NETunnelProviderManager wrapper
│   │   ├── MihomoAPI.swift        # REST client (URLSession)
│   │   ├── SubscriptionService.swift
│   │   └── IPCBridge.swift        # CFNotification + shared container
│   ├── Models/                    # SwiftData models
│   └── Resources/
│       ├── geoip.metadb
│       ├── geosite.dat
│       └── country.mmdb
├── PacketTunnel/                 # Network Extension target
│   ├── PacketTunnelProvider.swift # NEPacketTunnelProvider subclass
│   ├── TunnelEngine.swift         # Orchestrates Rust + Go
│   ├── IPCListener.swift          # CFNotification receiver
│   └── BridgingHeader.h           # imports mihomo_ios_ffi.h + mihomo_go.h
├── MeowCore/                     # Shared Swift package (or framework)
│   ├── include/
│   │   ├── mihomo_ios_ffi.h       # cbindgen output
│   │   └── mihomo_go.h            # cgo output
│   └── Frameworks/
│       ├── MihomoFfi.xcframework  # Rust static lib
│       └── MihomoGo.xcframework   # Go static lib
└── docs/
    ├── PRD.md
    └── PROJECT_PLAN.md
```

### 6.4 App Groups & Entitlements

Both app target and PacketTunnel extension must share:
- App Group: `group.io.github.madeye.meow`
- Network Extension entitlement: `com.apple.developer.networking.networkextension` → `packet-tunnel-provider`
- Keychain group (for future credential storage)

---

## 7. Milestones

### Milestone 0: Project Setup (Week 1)
- Xcode project scaffold with both targets (App + PacketTunnel)
- App Group, entitlements, signing configured
- CI pipeline (Xcode Cloud or GitHub Actions) building both targets
- Rust toolchain configured for iOS cross-compilation
- Go toolchain configured for iOS cross-compilation

### Milestone 1: Native Core Running (Weeks 2–3)
- `mihomo-ios-ffi` Rust crate builds as XCFramework
- `mihomo-core` Go package builds as XCFramework
- PacketTunnelProvider can load config.yaml and start mihomo engine
- TUN → Rust tun2socks → Go mihomo → upstream: traffic flows end-to-end
- Verified manually via device with a test subscription

### Milestone 2: VPN Toggle + Basic UI (Weeks 4–5)
- Home screen with VPN connect/disconnect
- VPN state and traffic rate displayed
- Subscriptions screen: add, refresh, delete, select
- Settings screen: core settings persisted

### Milestone 3: Proxy Control & Real-time Views (Weeks 6–7)
- Proxy group selection on Home screen
- Route mode selector
- Connections screen with live polling
- Rules screen
- Logs screen with WebSocket streaming

### Milestone 4: Config Management & Diagnostics (Week 8)
- YAML editor with save/revert
- YAML validation via C FFI
- Diagnostics screen (TCP/proxy/DNS tests)
- Providers view

### Milestone 5: Traffic History & Polish (Weeks 9–10)
- Daily traffic accumulation in SwiftData
- Traffic screen with Swift Charts (speed graph + daily bar chart)
- iOS 26 Liquid Glass UI polish pass
- Dark mode, Dynamic Type, accessibility audit
- App icons, launch screen

### Milestone 6: Testing & App Store Submission (Weeks 11–12)
- Full regression test pass on physical devices (iPhone 15+, iOS 26)
- Performance profiling (memory, battery in Instruments)
- App Store metadata, screenshots, privacy policy
- TestFlight beta
- App Store submission

---

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Network Extension memory limit (15MB iOS default, ~50MB in recent iOS) | High | Critical | Profile early; minimize allocations in extension; use Go's `-ldflags="-w -s"` to reduce binary size; request `com.apple.developer.networking.networkextension` entitlement with higher memory if needed |
| Go binary size bloat on iOS | High | Medium | Strip debug symbols (`-w -s`); use build tags to exclude unused protocols |
| Apple review rejection for VPN apps | Medium | High | Ensure app description clearly states legitimate use; include privacy policy; avoid keywords that trigger review flags |
| iOS Network Extension sandbox restricts file I/O paths | Medium | High | All file I/O must use App Group container path; verify early in M1 |
| Rust cross-compilation for iOS simulator (arm64 vs x86_64) | Medium | Medium | Use `cargo-lipo` or lipo to produce fat binaries; test simulator early |
| Per-app routing not feasible on iOS | High | Low (Post-MVP) | Document limitation clearly; defer to Post-MVP research phase |
| Go cgo + iOS build toolchain compatibility | Medium | High | Pin Go version; document exact Xcode/clang versions; test on CI from day 1 |
| CFNotification IPC latency for traffic updates | Low | Medium | Benchmark early; fall back to polling if 500ms updates are janky |
| smoltcp/netstack compatibility with iOS packet format | Low | High | Rust tun2socks already proven on Linux/Android; test TUN packet framing on iOS early (M1) |
| App Store guidelines §5.4 (VPN apps require MDM or developer distribution) | Low | Critical | meow-ios will use a standard NEPacketTunnelProvider which is permitted for consumer distribution; ensure correct entitlement type |
