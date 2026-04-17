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
MeowCore/         Headers + XCFrameworks for Rust and Go native libs
core/rust/        mihomo-ios-ffi (Rust tun2socks + DoH)
core/go/          mihomo-ios (Go mihomo proxy engine)
scripts/          Build scripts for native libs and Xcode project
docs/             PRD, project plan, build docs
```

## Building

The Xcode project is generated from `project.yml` via
[`xcodegen`](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
./scripts/generate-xcodeproj.sh
```

Native libraries are built separately and wrapped as XCFrameworks:

```sh
./scripts/build-rust.sh   # → MeowCore/Frameworks/MihomoFfi.xcframework
./scripts/build-go.sh     # → MeowCore/Frameworks/MihomoGo.xcframework
```

See [`docs/BUILD.md`](docs/BUILD.md) for toolchain requirements.
