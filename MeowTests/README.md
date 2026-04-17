# MeowTests — Unit Tests

Unit test bundle for the `meow-ios` app target. Linked against the main app via
`@testable import meow_ios`. Covers services, parsers, view models, FFI
wrappers, and data models.

See `docs/TEST_STRATEGY.md` §3 for the full plan.

## Layout

- `FFI/` — Swift↔Rust and Swift↔Go bridge tests (callable symbols, string
  marshaling, error propagation).
- `Parsing/` — Clash YAML, v2rayN nodelist, and YAML patcher tests.
- `Models/` — SwiftData model and migration tests.
- `Services/` — `SubscriptionService`, `VpnManager`, `TrafficAccumulator`.
- `API/` — `MihomoAPI` REST client with `URLProtocolStub`.
- `IPC/` — `SharedStore` and `DarwinBridge` coverage beyond `MeowSharedTests`.
- `Security/` — Keychain, URL validation, YAML sanitization.
- `Fixtures/` — checked-in YAML + nodelist inputs.
- `Support/` — shared helpers (`URLProtocolStub`, SwiftData test container).

## Running

```sh
xcodebuild test \
    -project meow-ios.xcodeproj \
    -scheme meow-ios \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -only-testing:MeowTests
```

Tests use Swift Testing (`@Test` / `@Suite`) by default; legacy XCTest is used
where `measure` or interruption-monitor APIs are required.
