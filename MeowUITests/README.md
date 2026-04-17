# MeowUITests — XCUITest

Flow-level UI tests for the `meow-ios` app. Run against the iOS Simulator;
the app under test uses injected launch arguments to bypass the real
NetworkExtension and stub REST responses.

See `docs/TEST_STRATEGY.md` §5 for the full plan.

## Launch arguments

- `-UITests` — enables the test-only `MihomoAPI` stub and in-memory SwiftData
- `-ResetState` — wipes all persisted state before launch
- `-StubURL <url>` — optional override for the REST base URL (defaults to a
  local echo server started by `MeowUITests/Support/TestServer.swift`)

## Layout

- `Flows/` — user journeys (add subscription, connect VPN, edit YAML)
- `Screens/` — per-screen verifications (Home tiles update, Connections row
  swipe, YAML editor validation)
- `Support/` — page objects, test-server helpers, interruption monitors

## Running

```sh
xcodebuild test \
    -project meow-ios.xcodeproj \
    -scheme meow-ios \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -only-testing:MeowUITests
```
