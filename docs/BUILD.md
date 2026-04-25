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

## Signing

`project.yml` no longer pins a `DEVELOPMENT_TEAM`. Build paths:

- **Simulator builds** — no signing required; Xcode uses its ad-hoc "Sign to
  Run Locally" identity automatically. Contributors can compile and run on
  any iOS simulator without an Apple Developer account.
- **Device builds** — open `meow-ios.xcodeproj` in Xcode, select each target
  under Signing & Capabilities, and pick your team. For command-line builds,
  put your local signing overrides in `Local.xcconfig`:

```xcconfig
// Local build settings — DO NOT COMMIT
DEVELOPMENT_TEAM = <TEAM_ID>
APP_STORE_CONNECT_API_KEY_P8 = /absolute/path/to/AuthKey_<ASC_KEY_ID>.p8
```

  `scripts/build-release.sh` passes `-xcconfig Local.xcconfig` to `xcodebuild`
  and reads `DEVELOPMENT_TEAM` from there by default. It also reads
  `APP_STORE_CONNECT_API_KEY_P8` (or `SIGN_KEY_PATH`) so local release
  credentials live in one place.
- **CI release** (tag push → `release.yml`) uses App Store Connect API
  secrets (`APP_STORE_CONNECT_API_KEY_P8` / `KEY_ID` / `ISSUER_ID`); no
  team is embedded in the repo.

## Firebase config

The app links `FirebaseAnalytics` and expects `GoogleService-Info.plist` at
`App/Resources/GoogleService-Info.plist`. The file is gitignored — fetch your
own copy from <https://console.firebase.google.com/> → Project Settings →
General → "Your apps" → Download GoogleService-Info.plist. Drop it at that
path; the build picks it up from disk regardless of git state. Without it,
`FirebaseApp.configure()` will crash at launch on a real run; building still
succeeds.

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

For a signed device-ready Release build from the command line, use:

```sh
./scripts/build-release.sh
```

To build and install onto a connected iPhone:

```sh
./scripts/build-release.sh --device <device-id> --install
```

The script writes Xcode outputs into `build/DerivedData`, refreshes Swift
packages in `build/SourcePackages`, rebuilds `MihomoCore.xcframework` by
default, and emits the final `.app` path on success. Use `--xcconfig <path>`
or `--team <TEAM_ID>` only if you need to override `Local.xcconfig`.

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
