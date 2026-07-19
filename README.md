# meow-ios

Native iOS port of the Android "meow" VPN/proxy client. Full meow-rs proxy engine
wrapped in a SwiftUI material UI with a NetworkExtension packet
tunnel provider.

## Install

[<img src="https://img.shields.io/badge/TestFlight-Public%20Beta-0070F5?style=for-the-badge&logo=apple&logoColor=white" alt="Join the TestFlight public beta" height="60">](https://testflight.apple.com/join/HSptQN3h)

Public beta is open on TestFlight: <https://testflight.apple.com/join/HSptQN3h>.
Requires iOS 17 or later (iPhone and iPad). Bring your own Mihomo / Clash
subscription — meow does not provide proxy servers.

Latest version: **v1.4.0** (July 2026) — dark mode across the app, QR-code
export for `ss://` profiles and subscription URLs, and a refreshed cat
branding. Since then, `main` also picked up a wake-from-idle reliability
fix — after sleep/wake the tunnel probes its data path and only restarts
when the probe fails — plus a meow-rs engine bump to 0.18.0 and a leading
swipe menu for refreshing individual subscriptions. See the
[release notes](https://github.com/madeye/meow-ios/releases) for earlier
per-version changelogs.

## Status

Public beta on TestFlight; the first App Store release (v1.4.0) is in
review. See [`docs/PRD.md`](docs/PRD.md) and
[`docs/PROJECT_PLAN.md`](docs/PROJECT_PLAN.md) for the product spec and task
breakdown.

## Layout

```
App/              SwiftUI app target
PacketTunnel/     NEPacketTunnelProvider extension target
MeowShared/       Swift package shared between app and extension
MeowCore/         Unified C header + XCFramework for the Rust native lib
core/rust/        meow-ios-ffi (meow-rs engine + tun2socks + DoH)
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
./scripts/build-rust.sh   # → MeowCore/Frameworks/MeowCore.xcframework
```

See [`docs/BUILD.md`](docs/BUILD.md) for toolchain requirements.

## License

[MIT](LICENSE) © 2026 Max Lv
