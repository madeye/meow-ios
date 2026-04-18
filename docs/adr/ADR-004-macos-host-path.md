# ADR-004: macOS Host Path for M1.5 Gate

**Status:** Proposed — awaiting user decision  
**Date:** 2026-04-18  
**Context layer:** M1.5 ship gate (LocalE2ETests / nightly vphone gate)  
**Supersedes:** part of PRD §7 M1.5 milestone (nightly Tart-vphone harness)  
**Depends on:** ADR-001 pure-Rust core (PRD v1.1), ADR-003 Liquid Glass UI

---

## 1. Context

The original M1.5 gate plan ran the meow-ios app inside a virtual iPhone (`vphone-cli`) hosted in a macOS Tart VM. That plan has failed at the virtualization layer: Apple Virtualization.framework **does not support nested virtualization for macOS guests** (only Linux guests). The nightly vphone-in-Tart path is architecturally blocked and is not coming back without either a non-VF host or a bare-metal device farm.

Separately, the iOS 26 simulator has **no `nesessionmanager` daemon**, so `NETunnelProviderManager.saveToPreferences` / `startTunnel` return `NEVPNErrorDomain Code=5 "IPC failed"` every time. This caps local XCUITest coverage at seeder + NE-error-surface UX (PR #12's β pivot); the tunnel cannot actually connect on sim.

The user now wants the meow-ios app running natively on their M4 Mac mini as a "universal app," to serve as the M1.5 gate host. The term "universal" is ambiguous across three concrete Apple paths. This ADR captures the delta per path so the user's pick becomes the authoritative implementation plan.

## 2. Current State (ground truth, 2026-04-18 on main @ `a124568`)

| Property | App target `meow-ios` | Extension `PacketTunnel` |
|---|---|---|
| `type` | `application` | `app-extension` (PlugIn bundle) |
| `platform` | iOS | iOS |
| Deployment target | iOS 26.0 | iOS 26.0 |
| `TARGETED_DEVICE_FAMILY` | `"1,2"` (iPhone + iPad) | — |
| `SUPPORTS_MACCATALYST` | NO (globally) | — |
| Bundle ID | `io.github.madeye.meow` | `io.github.madeye.meow.PacketTunnel` |
| Signing team | `345Y8TX7HZ` (Apple Dev, Automatic) | inherited |
| Principal class | — | `$(PRODUCT_MODULE_NAME).PacketTunnelProvider : NEPacketTunnelProvider` |
| `NSExtensionPointIdentifier` | — | `com.apple.networkextension.packet-tunnel` |

**Entitlements** (identical on both targets):

- `com.apple.security.application-groups` = `group.io.github.madeye.meow`
- `com.apple.developer.networking.networkextension` = `[packet-tunnel-provider]`
- `keychain-access-groups` = `[$(AppIdentifierPrefix)io.github.madeye.meow]`

**Binary constraints:**

- `MihomoCore.xcframework` slices TODAY: `ios-arm64` + `ios-arm64-simulator` only (Info.plist verified).
- `scripts/build-rust.sh` targets: `aarch64-apple-ios` + `aarch64-apple-ios-sim` only.
- Both targets link `-ObjC` + bridging header. Cross-platform-friendly.

**First-order macOS-compat flags in app code:**

- `App/Sources/Views/YamlEditorView.swift` — imports UIKit
- `App/Sources/Views/DiagnosticsViewController.swift` — imports UIKit
- `MeowCore/`, `MeowShared/` — clean, no UIKit / UIApplication / UIScreen / UIDevice references. Core is portable across all three paths.
- `App/Info.plist` sets `LSRequiresIPhoneOS: true` — **blocks iOSAppOnMac**.

## 3. Options

Each section below is an independent implementation plan. The user's pick determines which one promotes to the M1.5 milestone spec.

### (α) iOSAppOnMac — "Designed for iPad" on Apple Silicon

Run the existing iOS binary, unmodified, on macOS via the Apple Silicon compatibility runtime.

**What changes:**

| Area | Change |
|---|---|
| `project.yml` | Add `supportedDestinations: [iOS, macOS]` on `meow-ios` target (or equivalent xcodegen syntax producing `SUPPORTED_PLATFORMS += macosx` + `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES`). |
| `App/Info.plist` | Remove `LSRequiresIPhoneOS` (or set `false`). Drop `UIRequiredDeviceCapabilities: [arm64]` (blocks runtime). |
| Entitlements | No change in declared entitlement list. Runtime caveat: `packet-tunnel-provider` under iOSAppOnMac goes through Apple's iOS-on-macOS NE compatibility path. Historically patchy — needs validation spike on device before committing. |
| New targets | None |
| xcframework slices | No change — Apple Silicon Mac runs the `ios-arm64` slice natively. |
| App code | None required |
| Signing | Same iOS provisioning profile — Apple Silicon Mac accepts it. |
| SwiftUI idiom | iOS idiom preserved (looks like iOS on Mac — not a macOS-native feel). |

**Effort:** Low — single flag + 2 plist edits.  
**Risk:** Medium — NE packet-tunnel support under iOSAppOnMac is not guaranteed stable across macOS versions. **Mandatory validation spike** before this becomes the M1.5 plan: stand up the branch on user's M4 Mac mini, call `NETunnelProviderManager.saveToPreferences` + `startVPNTunnel`, confirm the real NE stack services the call (not a silent no-op).

### (β) Mac Catalyst

Same binary compiled with the Catalyst macOS variant (iPad UIKit under an AppKit shell).

**What changes:**

| Area | Change |
|---|---|
| `project.yml` | `SUPPORTS_MACCATALYST: YES` on `meow-ios` + `PacketTunnel`. Add `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: YES` or explicit `maccatalystProductBundleIdentifier`. |
| `App/Info.plist` | Add `LSApplicationCategoryType`, `LSMinimumSystemVersion`. `LSRequiresIPhoneOS` can stay (Catalyst ignores). |
| Entitlements | Catalyst auto-adds `com.apple.security.app-sandbox: true`. Verify app-group + NE under sandbox (usually fine). |
| New targets | None. |
| xcframework slices | **Blocker.** Add `ios-arm64-maccatalyst` + `ios-x86_64-maccatalyst` slices. Rust targets: `aarch64-apple-ios-macabi` + `x86_64-apple-ios-macabi`. `scripts/build-rust.sh` extension required. |
| App code | Two UIKit imports (YamlEditorView, DiagnosticsViewController) compile unchanged under Catalyst. Optional polish: branch on `UIDevice.current.userInterfaceIdiom == .mac` for macOS-idiom toolbars/menus. |
| Signing | Same Automatic signing with iOS profile; for direct distribution needs `Developer ID Application` (`SK4GFF6AHN` per global CLAUDE.md). |
| SwiftUI idiom | "iPad-on-Mac" feel — between iOS and macOS-native. |

**Effort:** Medium — Rust build script + xcframework repack are real work. Swift side is trivial.  
**Risk:** Medium — NE PTP bundled as PlugIn app-extension is Catalyst-supported since macOS 11, but the sandbox + app-group + keychain-access-groups combination under Catalyst is occasionally finicky; plan a day of plumbing.

### (γ) Native macOS target

New `macOS` app target sharing the MeowCore / MeowShared / MeowIPC libraries, with platform-conditional SwiftUI views and a macOS-specific PacketTunnel extension (either PlugIn app-extension or SystemExtension — modern macOS NE leans SystemExtension, but PlugIn still works).

**What changes:**

| Area | Change |
|---|---|
| `project.yml` | New target `meow-macos: type: application platform: macOS deploymentTarget: macOS 26.0`. Either a parallel `PacketTunnelMac` extension target, or promote the existing extension to a multi-platform target with conditional settings. If sysex: `type: system-extension` with macOS-only bundle identifier convention. |
| `App/Info.plist` | New macOS Info.plist. AppKit-style keys (`NSPrincipalClass`, `LSApplicationCategoryType`, etc.). |
| Entitlements | If SystemExtension: `com.apple.developer.system-extension.install` on main app + NE entitlements on sysex. Otherwise regular NE entitlements on PlugIn. Plus `com.apple.security.app-sandbox: true` for App Store distribution. |
| New targets | **Yes** — one (macOS app, PlugIn extension shared) or two (macOS app + macOS-specific extension). |
| xcframework slices | **Blocker.** Add `macos-arm64` + `macos-x86_64` slices. Rust targets: `aarch64-apple-darwin` + `x86_64-apple-darwin`. Same `scripts/build-rust.sh` extension as Catalyst, different slice names. |
| App code | `YamlEditorView.swift` + `DiagnosticsViewController.swift` need AppKit equivalents OR `#if os(iOS)` / `#if os(macOS)` fences. SwiftUI Home / Connections / Rules / Logs need macOS-idiom review: sidebar navigation, toolbar buttons, window management, menu bar items. The iOS 26 Liquid Glass design system does NOT fully apply on macOS 15; macOS 26 Tahoe brings its own Liquid Glass variant which would be the right target. |
| Signing | For App Store: Mac App Store distribution profile. For direct: `Developer ID Application` (`SK4GFF6AHN`) + notarization. |
| SwiftUI idiom | Fully macOS-native — sidebar, toolbar, menu bar, Liquid Glass macOS variant. |

**Effort:** Highest — new target(s) + platform-conditional SwiftUI + new xcframework slices + possibly sysex migration. Estimate 1–2 weeks for a polished result, more if UI is reworked to native macOS patterns (vs. just compiling).  
**Risk:** Lowest functional risk — native macOS NE is first-class and stable. Highest scope risk — the "polished Mac-native" ceiling is unbounded.

## 4. Decision Matrix

| Criterion | (α) iOSAppOnMac | (β) Catalyst | (γ) Native macOS |
|---|---|---|---|
| Time to M1.5 gate unblock | Days | ~1 week | 1–2+ weeks |
| NE PTP runtime reliability | ⚠️ unvalidated | ✅ supported since macOS 11 | ✅ first-class |
| xcframework rework | None | Catalyst slices | Darwin slices |
| SwiftUI code changes | None | Trivial | Significant |
| Mac-native feel | iOS-on-Mac | iPad-on-Mac | Native |
| Distribution reuse of iOS cert | ✅ | ✅ | Partial |
| Scope risk | Low | Medium | High |

## 5. Decision (pending)

The three paths are not mutually exclusive — (α) today unblocks M1.5, (γ) later ships a Mac-native app. (β) is useful only if the user explicitly wants one binary on both iOS + macOS App Store stores.

**Dev recommendation for user review:**

1. If **M1.5 gate is the only near-term goal**: pick (α). Run a 1-hour validation spike first (can `startVPNTunnel` actually succeed under iOSAppOnMac on macOS 26?). If yes, ship (α) as M1.5 host; defer (γ) as a later polish track.
2. If **the user is willing to accept 1–2 weeks of extra work for a native feel**: pick (γ) directly and treat M1.5 gate as bundled with the macOS port.
3. Pick (β) only if there's an App Store distribution reason to want one binary, not two.

Awaiting user pick. On pick:

- (α) → implementation ticket: update project.yml supported destinations + Info.plist. Spike first.
- (β) → implementation epic: (i) extend scripts/build-rust.sh for maccatalyst targets; (ii) repack xcframework; (iii) project.yml Catalyst flags; (iv) Catalyst-sandbox NE + app-group validation.
- (γ) → implementation epic: (i) extend scripts/build-rust.sh for darwin targets; (ii) repack xcframework; (iii) new macOS target in project.yml; (iv) platform-conditional SwiftUI pass; (v) macOS NE extension (decide PlugIn vs. SystemExtension); (vi) signing + notarization story.

## 6. Open questions

1. **(α) NE PTP runtime on macOS 26 iOSAppOnMac** — is `saveToPreferences` actually serviced or does it silently no-op? Needs device spike.
2. **(β/γ) Rust FFI slice parity** — is there anything in `mihomo-ios-ffi` that depends on iOS-specific system APIs (vs. generic Darwin)? A quick `grep -n "ios_" core/rust/mihomo-ios-ffi/src/*.rs` pre-pick would de-risk.
3. **(γ) SystemExtension vs PlugIn** — modern guidance leans sysex, but the existing PacketTunnelProvider is PlugIn-friendly. Which does the user want long-term?
4. **(γ) macOS 26 Tahoe Liquid Glass variant** — is there any internal Apple pre-release Dev the user is targeting, or ship against macOS 15 first and rev to 26 when it GAs?

## 7. References

- Dev audit inputs: project.yml, App/App.entitlements, PacketTunnel/PacketTunnel.entitlements, MihomoCore.xcframework Info.plist, scripts/build-rust.sh.
- PRD v1.3 §7 M1.5 gate (to be superseded by this ADR's outcome in PRD v1.4).
- PROJECT_PLAN T2.6 (Debug Diagnostics Panel) — its nightly assertion path depends on the host picked here.
- Project memory: `project_meow_ios_v14_pending.md` (two M1.5 blockers documented end-of-day 2026-04-17).
