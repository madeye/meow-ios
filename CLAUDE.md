# meow-ios — Contributor Guide for Claude

## Workflow Rules

### Run lint + tests locally before pushing

To save GitHub Actions minutes and keep the red-main failure mode from coming back, always run lint and the full relevant test suite locally before pushing to the remote.

- Before `git push` on any Swift / Rust / YAML change, run the local equivalents of the CI jobs your diff touches:
  - **Swift:** `xcodebuild test -project meow-ios.xcodeproj -scheme meow-ios -destination 'platform=iOS Simulator,name=iPhone 17'` against the relevant test bundles (`MeowTests`, `MeowUITests`, `MeowIntegrationTests`).
  - **Rust:** `scripts/build-rust.sh`, plus `cargo test` in `core/rust/mihomo-ios-ffi/` where relevant.
  - **Swift lint:** `swiftlint` **and** `swiftformat --lint .` at the repo root. CI's `lint` job runs both and fails if either does — passing one is not sufficient. The two tools have non-overlapping rule sets: swiftlint catches style/API-usage issues, swiftformat catches formatting/structural ones (`redundantSelf`, spacing, ordering, etc.). Install via `brew install swiftlint swiftformat` if missing.
- If a local run fails, fix it before pushing. Do not push "to see what CI says."
- Docs / infra-only changes (no Swift / Rust / YAML touched) don't need the full suite — skip what isn't relevant.
- Also check `gh run list --branch main --workflow=ci.yml --limit=1` before opening a PR so you know whether main's baseline is green. "Merging to red main" should be a known condition, not a discovery.

### Admin-bypass rebase-merge (when you can skip waiting for CI)

Two paths use `gh pr merge <n> --rebase --admin --delete-branch` to land a PR without waiting for the remote CI run to finish. Both require `--rebase` (keep commit history linear) and `--admin` (override required-checks). Pick the path that matches the PR's diff; when in doubt, run full CI.

#### Path A — Non-code PRs (docs, static assets, CLAUDE.md)

If a PR's diff touches only non-code paths, bypass CI regardless of local test state.

- "Non-code" = no changes under `App/`, `MeowCore/`, `MeowShared/`, `MeowTests/`, `MeowUITests/`, `MeowIntegrationTests/`, `core/`, `scripts/`, `project.yml`, `Cargo.*`, `Package.*`, `Podfile*`. Docs (`*.md`, `docs/`), CLAUDE.md, `.gitignore`, README, LICENSE, images, and other static assets are all safe to bypass.
- **Workflow files under `.github/workflows/*.yml` are NOT non-code for this rule.** Workflow logic can only be validated when the workflow actually runs (i.e., post-merge), so there is no local-CI-green substitute. Workflow-touching PRs always require a full remote CI run before merge.

#### Path B — Code PRs with local-CI-green attestation

If a PR's diff touches code paths (Swift, Rust, project.yml, Podfile, etc.), bypass is permitted **only** when ALL of the following are true and the PR description explicitly attests to each:

1. `swiftformat --lint .` ran locally at the repo root → 0 violations.
2. `swiftlint` ran locally at the repo root → 0 violations.
3. The `xcodebuild test` suites matching the diff ran locally on an iOS 26 simulator (e.g., iPhone 17) → all green. For Swift changes: at minimum `MeowTests`; add `MeowUITests` for UI diffs, `MeowIntegrationTests` for service-layer diffs. For Rust / FFI changes: add `scripts/build-rust.sh` + `cargo test` in `core/rust/mihomo-ios-ffi/`.
4. `git diff origin/main...HEAD --stat` was verified — the file list matches what the PR intends to change and contains no accidental additions. (The PR #28 admin-with-code lesson: bypassing without checking the diff base is how unintended code ends up in a skip-CI merge.)
5. PR description includes a checklist attesting to (1)-(4), with the concrete command lines that were run.

Caveats:
- **Workflow files (`.github/workflows/*.yml`) are still excluded from Path B** — same rationale as Path A. If the PR touches both workflow files and code, run full CI.
- If any of (1)-(4) was skipped or couldn't run cleanly, merge through full remote CI instead. Don't attest to a check you didn't actually run.
- Path B is a speed optimization, not a quality shortcut. If you're unsure whether a test bundle is relevant, run it — that's cheaper than discovering a regression on main.
- If a Path B merge surfaces a post-merge CI failure on main (lint, test, or build), the merger owns the immediate fix-forward PR. Bypass speed comes with bypass accountability.

#### When to use which

- Docs-only, CLAUDE.md, images, README → Path A.
- Swift / Rust / project.yml / Podfile → Path B, with attestation.
- Mixed (docs + code in one PR) → run full CI. (Consider splitting the PR if the docs half is blocking.)
- Workflow files (alone or mixed) → run full CI. Always.
