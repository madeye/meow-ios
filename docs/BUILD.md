# meow-ios build guide

> **Status:** bootstrap. The numbers below are the toolchain combinations we
> expect; verify on Apple Silicon with Xcode 26.4 before relying on them in
> CI.

## Toolchain requirements

| Component | Pinned version | Notes |
|-----------|----------------|-------|
| macOS | 15.x (Apple Silicon) | Required for iOS 26 SDK. |
| Xcode | 26.4 | Bundled clang + iOS 26 simulator. |
| Swift | 6.0 | Project uses strict concurrency. |
| Rust | 1.82+ | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` |
| Go | 1.23+ | CGO_ENABLED=1 for cross compilation. |
| xcodegen | 2.40+ | `brew install xcodegen` |
| cbindgen | 0.28+ | Installed as a Cargo dev-dependency. |

## One-time setup

```sh
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

## Regenerating the Xcode project

```sh
./scripts/generate-xcodeproj.sh
```

`meow-ios.xcodeproj` is git-ignored; always regenerate it from `project.yml`.

## Native library builds

Both scripts produce an XCFramework under `MeowCore/Frameworks/` and a header
under `MeowCore/include/`. Swift source is gated behind `MIHOMO_FFI_LINKED`
and `MIHOMO_GO_LINKED` so partial builds compile until both libs exist.

```sh
./scripts/build-rust.sh   # → MihomoFfi.xcframework
./scripts/build-go.sh     # → MihomoGo.xcframework
```

### Rust notes

- `crate-type = ["staticlib"]` — iOS cannot load dylibs from third-party
  locations, so we link statically into the extension.
- `profile.release`: `opt-level = "z"`, LTO, `panic = "abort"` — keeps the
  binary under the NetworkExtension memory ceiling.
- `cbindgen` emits `mihomo_ios_ffi.h` from `build.rs` on every build.

### Go notes

- Cross-compile requires `CC` and `CGO_CFLAGS` set to the target SDK clang and
  sysroot — `scripts/build-go.sh` handles both the device (`iphoneos`) and
  simulator (`iphonesimulator`) slices.
- `-ldflags '-s -w'` + `-trimpath` strip debug info; combined with upstream
  mihomo this still lands around 25MB per slice.
- The simulator build uses `GOARCH=arm64`; Intel simulators are not supported.

## Running locally

1. Generate the Xcode project: `./scripts/generate-xcodeproj.sh`
2. (Optional while UI-only) Build native libs: `./scripts/build-rust.sh && ./scripts/build-go.sh`
3. Open `meow-ios.xcodeproj`, select the `meow-ios` scheme.
4. Run on an iOS 26 simulator or a provisioned device.

When the XCFrameworks are absent the Swift source still compiles; engine
operations log a warning and no-op. CI marks native builds required for the
release configuration.

## App Group & entitlements

- App Group: `group.io.github.madeye.meow`
- NetworkExtension capability: `packet-tunnel-provider`
- Team: `345Y8TX7HZ` — managed via the App Store Connect API key under
  `~/.appstoreconnect/AuthKey_5MC8U9Z7P9.p8`.

Both targets share the App Group; the provider bundle id is
`io.github.madeye.meow.PacketTunnel` and is embedded in the main app bundle.

## Troubleshooting

- **`error: ld: library not found for -lmihomo_ios_ffi`** — run
  `./scripts/build-rust.sh`. The XCFramework is optional in `project.yml`
  (`optional: true`) so the app compiles without it, but the PacketTunnel
  target's link step still fails if a referenced symbol is used. The
  `MIHOMO_FFI_LINKED` conditional in `TunnelEngine.swift` routes around
  missing symbols.
- **Simulator runs but no VPN prompt** — `NETunnelProviderManager` requires
  the VPN configuration to be installed and accepted at least once per
  simulator. Check `Settings ▸ VPN & Device Management`.
- **`Swift strict concurrency` errors** — `SWIFT_STRICT_CONCURRENCY: complete`
  is enabled; preferred fix is `@MainActor` or `Sendable` conformance rather
  than widening visibility.
