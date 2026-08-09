# AppTV — the tvOS app target

`meow-tvos` is a second application target, not a second app. It ships the same
engine, the same App Group, and the same bundle identifier as `meow-ios`
(`com.tangzixiang.meow`) so the two are a universal purchase: one App Store
record, one price, both platform binaries.

## What it reuses

| Layer | Path | Shared? |
|---|---|---|
| Rust engine | `MeowCore.xcframework` | yes — `scripts/build-rust.sh` now packs `aarch64-apple-tvos{,-sim}` slices alongside the iOS pair |
| Tunnel provider | `PacketTunnel/Sources` | yes, byte-for-byte — pure Objective-C over NetworkExtension, no UIKit |
| Models | `App/Sources/Models` | yes |
| Services | `App/Sources/Services` | yes |
| App composition | `App/Sources/AppModel.swift`, `AppModelContainer.swift` | yes |
| Strings, GeoIP data | `App/Resources` (minus `Assets.xcassets`) | yes |
| Views | `App/Sources/Views` | **no** — replaced by `AppTV/Sources` |

Nothing under `Models/` or `Services/` imports UIKit or SwiftUI, which is what
makes the split above possible; keep it that way, or the tvOS target stops
building. `MeowTests` covers those files once, from the iOS target, and that
coverage carries over.

## What it replaces

`App/Sources/Views` is iPhone-shaped end to end — tab bar, sheets, swipe
actions, a camera QR scanner — so `AppTV/Sources` reimplements the one screen
Apple TV needs instead:

- `MeowTVApp.swift` — `@main`, identical service graph to `MeowApp`.
- `TVContentView.swift` — title, connect button, subscription-URL field,
  profile list.

The connect/disconnect sequencing in `TVContentView.toggle()` is a deliberate
copy of `GlobalVpnSwitchBar.toggle()`; the IPC intent must be queued before
`VpnManager.connect()` so the extension knows which profile to load on its
first config read. Change one, change both.

## Platform limits

- **tvOS 17.0 floor.** `NEPacketTunnelProvider` isn't available on Apple TV
  before it, and the whole app is the tunnel.
- **No QR scan.** Apple TV has no camera. Subscriptions arrive by URL only.
- **No alternate app icons.** `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`
  is iOS-only; `AppIcon.swift` still compiles (it's plain `Foundation`) but
  nothing on tvOS calls it.
- **No `.switch` toggle style** on tvOS 17, so the VPN control is a focusable
  button, not a `Toggle`.
- **No Brand Assets yet.** tvOS wants a layered App Icon + Top Shelf stack
  rather than the iOS `.appiconset`s, which is why `Assets.xcassets` is
  excluded from this target's sources. Required before App Store submission;
  not in this MVP.

## Building

```sh
scripts/build-rust.sh          # 4 slices: iOS + tvOS, device + simulator
xcodegen generate
xcodebuild build -project meow-ios.xcodeproj -scheme meow-tvos \
    -destination 'platform=tvOS Simulator,name=Apple TV'
```
