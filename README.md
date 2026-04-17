# meow-ios

Native iOS port of the Android "meow" VPN/proxy client. Full mihomo proxy engine
wrapped in a SwiftUI iOS 26 Liquid Glass UI with a NetworkExtension packet
tunnel provider.

## Status

Bootstrapping. See [`docs/PRD.md`](docs/PRD.md) and
[`docs/PROJECT_PLAN.md`](docs/PROJECT_PLAN.md) for the product spec and task
breakdown.

## Layout

```
App/              SwiftUI app target
PacketTunnel/     NEPacketTunnelProvider extension target
MeowShared/       Swift package shared between app and extension
MeowCore/         Unified C header + XCFramework for the Rust native lib
core/rust/        mihomo-ios-ffi (mihomo-rust engine + tun2socks + DoH)
scripts/          Build scripts for the native lib and Xcode project
docs/             PRD, project plan, build docs
```

## Building

The Xcode project is generated from `project.yml` via
[`xcodegen`](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
./scripts/generate-xcodeproj.sh
```

The native library is built separately and wrapped as a single XCFramework
that both the app and extension link against:

```sh
./scripts/build-rust.sh   # → MeowCore/Frameworks/MihomoCore.xcframework
```

See [`docs/BUILD.md`](docs/BUILD.md) for toolchain requirements.
