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

### Bypass CI + rebase-merge for non-code PRs

If a PR's diff touches only non-code paths — docs (`*.md`, `docs/`), non-CI workflow files, images, or other static assets — bypass CI and **rebase-merge** directly instead of waiting for a full CI run.

- "Non-code" = no changes under `App/`, `MeowCore/`, `MeowShared/`, `MeowTests/`, `MeowUITests/`, `MeowIntegrationTests/`, `core/`, `scripts/`, `.github/workflows/*.yml`, `project.yml`, `Cargo.*`, `Package.*`, `Podfile*`. Docs-only, CLAUDE.md, `.gitignore`, README, LICENSE, etc. are all safe to bypass.
- Use `gh pr merge <n> --rebase --admin --delete-branch` — the `--admin` flag overrides required-checks so the rebase-merge lands without waiting. `--rebase` keeps the commit history linear without squashing (useful if the PR has multiple meaningful commits).
- If a PR mixes docs + code changes, do NOT bypass — run the full CI. The bypass is only for strictly non-code diffs.
- Don't use this to skip CI on code changes that "feel small." Even a one-line Swift or Rust edit should go through the full pipeline.
