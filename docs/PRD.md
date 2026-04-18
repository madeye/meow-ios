# meow-ios Product Requirements Document

**Version:** 1.4  
**Date:** 2026-04-18  
**Author:** Architecture Team  
**Status:** Draft  
**Changelog:**
- v1.1 — Dropped Go mihomo core; replaced with pure-Rust mihomo-rust engine (single `MihomoCore.xcframework`). iOS NetworkExtension 15 MB memory limit motivation documented.
- v1.2 — Added §4.4 Diagnostics Surface Contract (OCR-stable label format for QA nightly harness). Memory budget tightened to TEST_STRATEGY v1.2: Extension ≤14 MB / 15 MB hard-fail; xcframework ≤8 MB.
- v1.3 — Removed `mihomo-listener` crate from Rust dependency list (not needed in in-process path). Noted subscription conversion (`src/subscription.rs`) and diagnostics (`src/diagnostics.rs`) as Rust-native replacements for old Go paths. Added non-DNS UDP gap as MVP known limitation and new risk row.
- v1.4 — Automated E2E scope retired per user directive 2026-04-18: vphone-cli nightly harness, tart-in-harness topology, and LocalE2ETests (Option 2 seeder + NE-error-surface) all dropped in favor of manual device verification on user's iPhone. §4.4 retitled to reflect manual-QA framing (label format stays useful for on-device readability; OCR contract removed). M1.5 milestone rewritten from "Nightly Gate Unblocked" to "Manual Smoke Passes".

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
└─────────────────────┬───────────────────────────────────┘
                      │ C FFI (cbindgen header)
          ┌───────────▼──────────────────────────────────┐
          │              MihomoCore.xcframework            │
          │         (single Rust static library)           │
          │                                                │
          │  ┌─────────────────┐  ┌─────────────────────┐ │
          │  │  tun2socks       │  │  mihomo-rust engine  │ │
          │  │  (netstack-      │  │  (proxy engine,      │ │
          │  │   smoltcp)       │  │   REST controller,   │ │
          │  │  DoH client      │  │   rules, DNS)        │ │
          │  └─────────────────┘  └─────────────────────┘ │
          └──────────────────────────────────────────────┘
```

> **Why pure Rust?** iOS NetworkExtension processes have a 15 MB memory ceiling. The previous design included a Go-compiled mihomo engine (~20–30 MB stripped binary alone), which exceeds that budget. Replacing it with [mihomo-rust](https://github.com/madeye/mihomo-rust) — a pure-Rust reimplementation of the mihomo proxy kernel — yields a single static library that fits within the memory constraint while eliminating the Go toolchain dependency entirely.

### 2.2 Layer Responsibilities

| Layer | Technology | Responsibility |
|-------|-----------|----------------|
| UI | SwiftUI + iOS 26 | All screens, navigation, state presentation |
| App ↔ Extension IPC | CFNotificationCenter + App Group container | Commands (connect/disconnect) and state/traffic events |
| Packet Tunnel Provider | NEPacketTunnelProvider | VPN lifecycle, TUN fd management |
| MihomoCore (Rust) | Rust, cbindgen C header, single XCFramework | tun2socks (netstack-smoltcp), DoH, full proxy engine (mihomo-rust), REST controller at 127.0.0.1:9090 |
| Persistence | SwiftData | Profiles, daily traffic history |
| Preferences | UserDefaults (App Group shared) | Port, DoH server, per-app mode |

### 2.3 VPN Data Path

```
iOS Network Stack
      ↓  all IP packets captured by NEPacketTunnelProvider
TUN interface (utun*)
      ↓  packets via packetFlow.readPackets() → Unix socket pair → Rust
netstack-smoltcp (Rust tun2socks)
      ↓  TCP streams  →  mihomo_tunnel::tcp::handle_tcp()   (in-process Tokio channel)
      ↓  UDP:53       →  DoH client  (short-circuit, in-process)
      ↓  UDP non-DNS  →  ⚠ NOT YET FORWARDED (see §3.3 and §8)
mihomo-rust engine  ←→  REST API (127.0.0.1:9090 inside extension)
      ↓  upstream proxy protocol (SS/Trojan/VLESS/WireGuard/TUIC/Hysteria2/etc.)
Remote proxy server
```

### 2.4 FFI Strategy

**Single Swift → Rust C bridge:**
- The `mihomo-ios-ffi` Cargo workspace crate links against mihomo-rust workspace crates as Rust dependencies
- The combined crate exports a flat C ABI via `#[no_mangle] pub extern "C"` functions
- `cbindgen` generates `MeowCore/include/mihomo_core.h`
- Swift calls these functions through `PacketTunnel/BridgingHeader.h`

**Rust dependency list** (as confirmed by Dev, commit `dd3d44a`):

| Crate | Role |
|-------|------|
| `mihomo-common` | Core traits and types |
| `mihomo-proxy` | Proxy protocol implementations |
| `mihomo-rules` | Rule matching engine |
| `mihomo-dns` | DNS resolver and DoH |
| `mihomo-tunnel` | Central routing engine (`tcp::handle_tcp`, `udp::handle_udp` — UDP path pending T2.9) |
| `mihomo-config` | YAML parsing; also backs `src/subscription.rs` (node list → Clash YAML conversion) |
| `mihomo-api` | REST controller (Axum) |
| ~~`mihomo-listener`~~ | ~~Inbound protocol handlers~~ — **removed**: not needed in in-process path (no loopback listener) |

**Rust-native replacement for old Go paths** (implemented in `dd3d44a`):
- `src/subscription.rs` — subscription conversion (was `convert.go` in Go core); uses `mihomo-config` crate
- `src/diagnostics.rs` — TCP/proxy/DNS diagnostic tests (was `diagnostics.go` in Go core)

**Complete C API surface:**
```c
// Engine lifecycle
void  meow_engine_set_home_dir(const char *dir);
int   meow_engine_start(const char *config_path, const char *api_addr, const char *secret);
void  meow_engine_stop(void);
int   meow_engine_is_running(void);
void  meow_engine_get_traffic(long long *upload, long long *download);
int   meow_engine_validate_config(const char *yaml, int len);
int   meow_engine_convert_subscription(const char *raw, int len, char *dst, int cap);
int   meow_engine_last_error(char *dst, int cap);
int   meow_engine_version(char *dst, int cap);

// Diagnostics (src/diagnostics.rs)
int   meow_test_direct_tcp(const char *host, int port, char *dst, int cap);
int   meow_test_proxy_http(const char *url, char *dst, int cap);
int   meow_test_dns_resolver(const char *addr, char *dst, int cap);

// TUN/tun2socks
int   meow_tun_start(int fd, int socks_port, int dns_port);
void  meow_tun_stop(void);
int   meow_tun_last_error(char *dst, int cap);
```

**No Go toolchain required.** One XCFramework (`MihomoCore.xcframework`) contains everything.

### 2.5 IPC Between App and Extension

iOS restricts direct process communication to/from Network Extensions. The chosen pattern:

- **Commands (App → Extension):** Write intent to shared `UserDefaults(suiteName: appGroupID)`, then post a `CFNotificationCenter.darwinNotify` named `com.meow.vpn.command`
- **State (Extension → App):** Extension writes state to shared container, posts `com.meow.vpn.state`
- **Traffic (Extension → App):** Extension writes a small traffic struct to the App Group container at 500ms intervals, posts `com.meow.vpn.traffic`

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
| Validate YAML | nativeValidateConfig() | meow_engine_validate_config() C FFI | MVP |
| Revert YAML | yamlBackup in Room | yamlBackup in SwiftData | MVP |
| DoH DNS | Rust doh_client.rs | Same Rust module (iOS target) | MVP |
| Settings (log level, IPv6, allow LAN) | SharedPreferences | UserDefaults | MVP |
| App version display | BuildConfig.VERSION_NAME | Bundle.main.infoDictionary | MVP |
| Memory usage display | GET /memory | GET /memory | MVP |
| Route mode (rule/global/direct) | PATCH /configs | PATCH /configs | MVP |
| Diagnostics (TCP/proxy/DNS tests) | nativeTest* (Go) | meow_test_* C FFI (Rust, src/diagnostics.rs) | MVP |
| Providers view | GET /providers | GET /providers | MVP |
| Proxy delay test | GET /proxies/{name}/delay | GET /proxies/{name}/delay | MVP |
| GeoIP/Geosite bundled assets | bundled in APK assets | bundled in app bundle | MVP |
| TCP proxying | Android VpnService + tun2socks | netstack-smoltcp → mihomo_tunnel::tcp::handle_tcp | MVP |

### 3.2 Post-MVP Features

| Feature | Notes |
|---------|-------|
| Non-DNS UDP forwarding | mihomo-rust UDP reverse-pump not yet wired for netstack-smoltcp integration. Tracked as T2.9. Breaks WireGuard, QUIC/HTTP3 when UDP path is taken. See §3.3 and §8. |
| Per-app routing | iOS NEPacketTunnelProvider does not support per-app allow/deny lists. Post-MVP: explore NEAppRule (MDM only) or DNS-based workaround. |
| Widget (traffic display) | WidgetKit extension showing current traffic rates |
| Siri shortcuts | "Start VPN" shortcut via AppIntents |
| iCloud sync of profiles | CloudKit integration for subscription sync across devices |
| Apple Watch companion | Glanceable VPN status + toggle |
| macOS Catalyst | Extend to Mac via Catalyst once iOS is stable |

### 3.3 Known MVP Limitations

| Limitation | User-visible impact | Workaround / Timeline |
|-----------|--------------------|-----------------------|
| **Non-DNS UDP not forwarded** | WireGuard tunnels will not pass traffic. QUIC/HTTP3 connections (YouTube, Google, Cloudflare sites) degrade to TCP HTTP/2 (typically transparent to user). UDP-only apps break silently. | Disclosed in M0 release notes. Patched in M1 (T2.9). TCP + DoH covers ~99% of observable iOS traffic. |

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

### 4.4 Diagnostics Surface Contract

> This section defines the label format for the Debug Diagnostics Panel used during **manual on-device verification** (v1.4, 2026-04-18). Prior v1.2/v1.3 framing around an OCR-stable contract for the vphone-cli nightly harness is superseded — the harness path is retired. The label format is kept because stable, glanceable text still helps the user run the smoke check on their iPhone. **Do not change label key strings unilaterally; they also back accessibilityIdentifier-based unit UI tests.**

The Debug Diagnostics Panel is accessible via `MEOW_DEBUG=1` launch argument or Settings → triple-tap version label (debug builds only). When active, it displays exactly 5 result labels, one per line, in the following fixed format:

```
CHECK_NAME: PASS
CHECK_NAME: FAIL(<reason>)
```

**Rules for label stability:**
- The `CHECK_NAME:` prefix is a fixed ASCII string — no localisation, no emoji, no dynamic insertion
- The `: ` separator is always ASCII colon + space
- `PASS` is always the literal 4-character uppercase string
- `FAIL(` is always the literal 5-character prefix; `<reason>` is a short ASCII diagnostic; `)` closes it
- Labels are rendered in a monospace `UILabel` with `accessibilityIdentifier` matching `CHECK_NAME` (e.g. `"TUN_EXISTS"`) — supports unit-level UI test anchoring and VoiceOver

**The 5 checks in display order:**

| # | CHECK_NAME | PASS condition | FAIL examples |
|---|-----------|----------------|---------------|
| 1 | `TUN_EXISTS` | `meow_engine_is_running()` == 1 AND utun interface present | `FAIL(engine_not_running)`, `FAIL(no_utun)` |
| 2 | `DNS_OK` | `apple.com` resolves to ≥1 A record via 172.19.0.2:53 within 3 s | `FAIL(timeout)`, `FAIL(nxdomain)` |
| 3 | `TCP_PROXY_OK` | TCP connect to `connectivitycheck.gstatic.com:443` succeeds through proxy within 5 s | `FAIL(timeout)`, `FAIL(refused)` |
| 4 | `HTTP_204_OK` | HTTP GET `http://connectivitycheck.gstatic.com/generate_204` returns status 204 | `FAIL(status=NNN)`, `FAIL(timeout)` |
| 5 | `MEM_OK` | Extension resident memory ≤ 14 MB | `FAIL(mem=NNmb>=15mb)` |

**Screen layout (fixed, must not reorder):**
```
┌─── Debug Diagnostics ───────────────────┐
│  TUN_EXISTS: PASS                        │
│  DNS_OK: PASS                            │
│  TCP_PROXY_OK: PASS                      │
│  HTTP_204_OK: PASS                       │
│  MEM_OK: PASS                            │
│                                          │
│  [Run Again]                             │
└──────────────────────────────────────────┘
```

The panel is a `UIViewController` (not SwiftUI) to ensure pixel-stable label positions across iOS versions — useful for glance-based manual verification.

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

### 6.1 Rust (mihomo-ios-ffi — unified crate)

A Cargo workspace at `core/rust/` contains:

```
core/rust/
├── Cargo.toml          # workspace manifest
├── mihomo-ios-ffi/     # C-ABI wrapper crate
│   ├── Cargo.toml      # depends on mihomo-rust workspace crates (see §2.4)
│   ├── src/
│   │   ├── lib.rs      # #[no_mangle] C exports
│   │   ├── engine.rs   # wraps mihomo-rust engine lifecycle
│   │   ├── tun2socks.rs # netstack-smoltcp TUN handler
│   │   ├── doh_client.rs
│   │   ├── subscription.rs  # node list → Clash YAML (was Go convert.go)
│   │   └── diagnostics.rs   # TCP/proxy/DNS tests (was Go diagnostics.go)
│   └── cbindgen.toml
└── vendor/mihomo-rust/ # git submodule: github.com/madeye/mihomo-rust
```

**Cross-compilation:**
```bash
# iOS device (arm64)
cargo build --target aarch64-apple-ios --release -p mihomo-ios-ffi

# iOS Simulator fat binary
cargo build --target aarch64-apple-ios-sim --release -p mihomo-ios-ffi
cargo build --target x86_64-apple-ios --release -p mihomo-ios-ffi
lipo -create \
  target/aarch64-apple-ios-sim/release/libmihomo_ios_ffi.a \
  target/x86_64-apple-ios/release/libmihomo_ios_ffi.a \
  -output libmihomo_ios_ffi_sim.a

# Generate header
cbindgen --config cbindgen.toml --output MeowCore/include/mihomo_core.h

# XCFramework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libmihomo_ios_ffi.a \
  -headers MeowCore/include/ \
  -library libmihomo_ios_ffi_sim.a \
  -headers MeowCore/include/ \
  -output MeowCore/Frameworks/MihomoCore.xcframework
```

**Output:** `MihomoCore.xcframework` — one framework, all functionality, target ≤8 MB stripped.

### 6.2 Xcode Project Structure

```
meow-ios/
├── meow-ios.xcodeproj
├── App/
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
│   ├── Services/
│   │   ├── VpnManager.swift
│   │   ├── MihomoAPI.swift
│   │   ├── SubscriptionService.swift
│   │   └── IPCBridge.swift
│   ├── Models/
│   └── Resources/
│       ├── geoip.metadb
│       ├── geosite.dat
│       └── country.mmdb
├── PacketTunnel/
│   ├── PacketTunnelProvider.swift
│   ├── TunnelEngine.swift
│   ├── DiagnosticsPanel.swift    # UIViewController for manual on-device smoke (§4.4)
│   ├── IPCListener.swift
│   └── BridgingHeader.h           # #import "mihomo_core.h"
├── MeowCore/
│   ├── include/
│   │   └── mihomo_core.h          # cbindgen output (single header)
│   └── Frameworks/
│       └── MihomoCore.xcframework
├── core/rust/
│   ├── Cargo.toml
│   ├── mihomo-ios-ffi/
│   └── vendor/mihomo-rust/
└── docs/
    ├── PRD.md
    └── PROJECT_PLAN.md
```

### 6.3 App Groups & Entitlements

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
- mihomo-rust added as git submodule; `mihomo-ios-ffi` workspace scaffolded

### Milestone 1: Native Core Running (Weeks 2–3)
- `MihomoCore.xcframework` (single Rust library) builds successfully; stripped size ≤ 8 MB
- PacketTunnelProvider can load config.yaml, start mihomo-rust engine, start tun2socks
- TCP traffic flows end-to-end through extension on device
- DoH DNS working (UDP:53 short-circuit)
- **Known limitation at M1:** non-DNS UDP not forwarded (WireGuard/QUIC degraded); disclosed in release notes

### Milestone 1.5: Manual Smoke Passes (End of Week 3)
- T2.6 (Debug Diagnostics Panel) complete; all 5 checks rendering on device with `MEOW_DEBUG=1`
- User runs manual smoke on their iPhone (iOS 26, real device) and confirms all 5 checks read `PASS`
- Gate is user sign-off, not an automated assertion; vphone-cli nightly harness is retired (v1.4)

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
- User-facing diagnostics screen (TCP/proxy/DNS tests)
- Providers view

### Milestone 5: Traffic History, UDP Patch & Polish (Weeks 9–10)
- Daily traffic accumulation in SwiftData
- Traffic screen with Swift Charts
- **T2.9 (non-DNS UDP):** wire netstack-smoltcp UDP → `mihomo_tunnel::udp::handle_udp` (pending upstream API maturity)
- iOS 26 Liquid Glass UI polish pass
- Dark mode, Dynamic Type, accessibility audit
- App icons, launch screen

### Milestone 6: Testing & App Store Submission (Weeks 11–12)
- Full regression test pass on physical devices (iPhone 15+, iOS 26)
- Performance profiling (memory target ≤14 MB, hard-fail 15 MB)
- App Store metadata, screenshots, privacy policy
- TestFlight beta
- App Store submission

---

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Network Extension memory limit | High | Critical | **Budget (TEST_STRATEGY v1.2):** Extension resident ≤ 14 MB PASS / ≥ 15 MB hard-fail; MihomoCore.xcframework stripped ≤ 8 MB. Both enforced as CI gates (T1.4 size check; T6.4 runtime measure). Rust release profile: `lto = "fat"`, `opt-level = "z"`, `strip = "symbols"`. Profile with Instruments Memory Graph in M1. |
| **Non-DNS UDP not forwarded (M0/M1 gap)** | **Confirmed** | **Medium** | **WireGuard tunnels break; QUIC/HTTP3 degrades to TCP HTTP/2 (usually transparent). Disclosed in M0 release notes. Patched in M1 via T2.9 (wire netstack-smoltcp UDP → `mihomo_tunnel::udp::handle_udp`). Prerequisite: upstream mihomo-rust UDP API maturity check.** |
| mihomo-rust protocol coverage gaps | Medium | Medium | Audit SS/Trojan/VLESS/WireGuard/TUIC/Hysteria2 support before M1 sign-off; gaps → implement, vendor, or defer |
| Rust binary size with all mihomo-rust crates | Medium | Medium | Use `cargo bloat`; enable LTO + `opt-level = "z"`; disable unused feature flags; CI hard-fails if xcframework > 8 MB |
| tun2socks in-process Tokio channel coupling | Medium | High | T1.2 prototype before Phase 2; fallback to SOCKS5 loopback (127.0.0.1:7890) if coupling is too complex |
| Apple review rejection for VPN apps | Medium | High | Ensure app description clearly states legitimate use; include privacy policy; avoid keywords that trigger review flags |
| iOS Network Extension sandbox restricts file I/O paths | Medium | High | All file I/O must use App Group container path; verify early in M1 |
| Rust cross-compilation for iOS simulator (arm64 vs x86_64) | Medium | Medium | Use `lipo` to produce fat simulator binary; test from day 1 on CI |
| Per-app routing not feasible on iOS | High | Low (Post-MVP) | Document limitation clearly; defer to Post-MVP research phase |
| CFNotification IPC latency for traffic updates | Low | Medium | Benchmark early; fall back to polling shared container if unreliable |
| smoltcp/netstack + iOS utun packet format | Low | High | Verify 4-byte AF family header handling (T1.3) on device in M1 |
| App Store guidelines §5.4 (VPN apps) | Low | Critical | Use `packet-tunnel-provider` entitlement; consumer distribution is permitted |
