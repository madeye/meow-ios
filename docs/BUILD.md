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
| xcodegen | 2.40+ | `brew install xcodegen` |
| cbindgen | 0.28+ | Installed as a Cargo dev-dependency. |

## One-time setup

```sh
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

## Regenerating the Xcode project

`project.yml` is the source of truth. `meow-ios.xcodeproj` is git-ignored
and generated output — never hand-edit `project.pbxproj`. If you add or
rename a target, source folder, or dependency, resync with:

```sh
./scripts/generate-xcodeproj.sh   # wraps `xcodegen generate`
```

If adding a new test bundle or source path and the generator misbehaves,
`xcodegen generate` can be invoked directly from the repo root to surface
its diagnostics. CI always regenerates from `project.yml`, so any drift
between the checked-in `project.yml` and a hand-edited `project.pbxproj`
will be silently overwritten.

## Native library builds

There is no Go toolchain. The NetworkExtension memory ceiling (15 MB resident
on iOS) forbids the Go runtime, so the proxy engine is
[`mihomo-rust`](https://github.com/madeye/mihomo-rust) embedded into our FFI
crate as a Cargo dependency. Only one static library ships.

`scripts/build-rust.sh` produces `MeowCore/Frameworks/MihomoCore.xcframework`
and the `MeowCore/include/mihomo_core.h` header. Both the app and extension
link the same XCFramework directly — there is no `MIHOMO_CORE_LINKED`
conditional; the framework is declared `optional: true` in `project.yml`
so source compiles before the `.a` exists, but link fails without it.

```sh
./scripts/build-rust.sh   # → MihomoCore.xcframework
```

### Rust notes

- `crate-type = ["staticlib"]` — iOS cannot load dylibs from third-party
  locations, so we link statically into the extension.
- `profile.release`: `opt-level = "z"`, LTO, `panic = "abort"` — keeps the
  binary under the NetworkExtension memory ceiling.
- Xcode's default Release strip leaves Swift/Obj-C metadata in the linked
  binary; a `strip -Sx` postBuildScript on the `meow-ios` and `PacketTunnel`
  targets (see `project.yml`) takes the `.appex` from ~8.8 MB to ~5.6 MB,
  under the 8 MB TEST_STRATEGY §8.1 ceiling. Removing that script will fail
  QA's CI size gate.
- `cbindgen` emits `mihomo_core.h` from `build.rs` on every build.
- Mihomo crates pulled as git deps (`mihomo-common`, `mihomo-config`,
  `mihomo-dns`, `mihomo-tunnel`, `mihomo-api`, `mihomo-proxy`) from
  `github.com/madeye/mihomo-rust`. The FFI crate owns the tokio runtime,
  hosts the mihomo-rust engine directly, and dispatches tun2socks flows
  in-process through `mihomo_tunnel::tcp::handle_tcp` — no SOCKS5 loopback.

## Running locally

1. Generate the Xcode project: `./scripts/generate-xcodeproj.sh`
2. (Optional while UI-only) Build the native lib: `./scripts/build-rust.sh`
3. Open `meow-ios.xcodeproj`, select the `meow-ios` scheme.
4. Run on an iOS 26 simulator or a provisioned device.

When the XCFramework is absent the Swift source still compiles; engine
operations log a warning and no-op. CI marks the native build required for
the release configuration.

## App Group & entitlements

- App Group: `group.io.github.madeye.meow`
- NetworkExtension capability: `packet-tunnel-provider`
- Team: `<TEAM_ID>` — managed via the App Store Connect API key under
  `~/.appstoreconnect/AuthKey_<ASC_KEY_ID>.p8`.

Both targets share the App Group; the provider bundle id is
`io.github.madeye.meow.PacketTunnel` and is embedded in the main app bundle.

## Troubleshooting

- **`error: ld: library not found for -lmihomo_ios_ffi`** — run
  `./scripts/build-rust.sh`. The XCFramework is optional in `project.yml`
  (`optional: true`) so the app compiles without it, but any target's link
  step still fails if a referenced symbol is used.
- **Simulator runs but no VPN prompt** — `NETunnelProviderManager` requires
  the VPN configuration to be installed and accepted at least once per
  simulator. Check `Settings ▸ VPN & Device Management`.
- **`Swift strict concurrency` errors** — `SWIFT_STRICT_CONCURRENCY: complete`
  is enabled; preferred fix is `@MainActor` or `Sendable` conformance rather
  than widening visibility.
