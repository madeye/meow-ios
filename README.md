# meow-ios

Native iOS port of the Android "meow" VPN/proxy client. Full mihomo proxy engine
wrapped in a SwiftUI iOS 26 Liquid Glass UI with a NetworkExtension packet
tunnel provider.

## Install

[<img src="https://img.shields.io/badge/TestFlight-Public%20Beta-0070F5?style=for-the-badge&logo=apple&logoColor=white" alt="Join the TestFlight public beta" height="60">](https://testflight.apple.com/join/nnDAn7ZH)

Public beta is open on TestFlight: <https://testflight.apple.com/join/nnDAn7ZH>.
Requires iOS 26 or later (iPhone and iPad). Bring your own Mihomo / Clash
subscription — meow does not provide proxy servers.

## Status

Public beta. See [`docs/PRD.md`](docs/PRD.md) and
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

## License

[MIT](LICENSE) © 2026 Max Lv
