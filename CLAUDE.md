# meow-ios — Contributor Guide for Claude

## Workflow Rules

### Run lint + tests locally before pushing

To save GitHub Actions minutes and keep the red-main failure mode from coming back, always run lint and the full relevant test suite locally before pushing to the remote.

- Before `git push` on any Swift / Rust / YAML change, run the local equivalents of the CI jobs your diff touches:
  - **Swift:** `xcodebuild test -project meow-ios.xcodeproj -scheme meow-ios -destination 'platform=iOS Simulator,name=iPhone 17'` against the relevant test bundles (`MeowTests`, `MeowUITests`, `MeowIntegrationTests`).
  - **Rust:** `scripts/build-rust.sh`, plus `cargo test` in `core/rust/mihomo-ios-ffi/` where relevant.
  - **Lint:** `swiftlint` at the repo root.
- If a local run fails, fix it before pushing. Do not push "to see what CI says."
- Docs / infra-only changes (no Swift / Rust / YAML touched) don't need the full suite — skip what isn't relevant.
- Also check `gh run list --branch main --workflow=ci.yml --limit=1` before opening a PR so you know whether main's baseline is green. "Merging to red main" should be a known condition, not a discovery.
