# MeowIntegrationTests

Integration-tier tests that exercise real subsystems — the NetworkExtension
lifecycle, the Rust + Go FFI libraries, IPC end-to-end, and SwiftData under
concurrent access.

See `docs/TEST_STRATEGY.md` §4.

## Why a separate bundle?

Unit tests (`MeowTests`) run in the app process with everything stubbed.
These tests run against the actual extension process, actual FFI libraries,
and actual shared App Group container — they need entitlements the unit
bundle doesn't have, and they cannot run on Xcode Cloud without a
provisioned test runner.

## Layout

- `VPNLifecycle/` — `NETunnelProviderManager` lifecycle, crash recovery,
  sleep/wake
- `EngineIntegration/` — Rust tun2socks + Go mihomo engine coexistence,
  REST controller reachability, DoH bootstrap
- `IPC/` — App↔Extension command and state round-trips, throughput, races
- `SwiftData/` — concurrent profile access, large DailyTraffic queries,
  schema migration

## Running

Requires a provisioned device or a simulator with the App Group entitlement:

```sh
xcodebuild test \
    -project meow-ios.xcodeproj \
    -scheme meow-ios \
    -destination 'platform=iOS,id=<device-id>' \
    -only-testing:MeowIntegrationTests
```
