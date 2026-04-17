# Self-hosted GitHub Actions Runner (Tart VM)

**Status:** 2026-04-17 — runner not yet registered on `github.com/madeye/meow-ios`. `nightly.yml` references `runs-on: [self-hosted, macOS, apple-silicon, tart]`; until the runner registers with that label set, the job sits queued.

**Scope decision (2026-04-17 team-lead):** nightly E2E runs **only inside the Tart VM** — no Mac mini fallback. See [`TEST_FIXTURES.md §5`](./TEST_FIXTURES.md) for the image-reuse decision (`bld-e2e-base`, layered via `scripts/provision-tart-fixtures.sh`).

This file is the manual setup runbook the user follows **once per VM build** to register a self-hosted runner inside that Tart image.

---

## 1. Prereqs inside the Tart VM

```bash
# Fixture binaries (layered delta on the local base; idempotent)
./scripts/provision-tart-fixtures.sh

# Host-side build + virt tools the nightly workflow invokes
brew install tart xcodegen xcbeautify

# Self-hosted runner bits
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL -o actions-runner-osx-arm64.tar.gz \
  https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64-2.322.0.tar.gz
tar xzf actions-runner-osx-arm64.tar.gz
```

Confirm the VM has SIP disabled (`csrutil status`) — vphone-cli requires it (see [`TEST_STRATEGY.md §7`](./TEST_STRATEGY.md)). If not, boot into Recovery and disable before continuing.

---

## 2. Register the runner

GitHub issues a **short-lived registration token** — valid ~1 hour. Generate a fresh one per registration at:

> https://github.com/madeye/meow-ios/settings/actions/runners/new

Never commit the token to the repo. Pass it only on the registration command line inside the VM:

```bash
cd ~/actions-runner
./config.sh \
  --url    https://github.com/madeye/meow-ios \
  --token  <TOKEN> \
  --name   meow-tart-$(hostname -s) \
  --labels self-hosted,macOS,apple-silicon,tart \
  --work   _work \
  --unattended \
  --replace
```

Label set must match `nightly.yml`'s `runs-on` selector exactly — missing any one label leaves the job queued:
- `self-hosted`
- `macOS`
- `apple-silicon`
- `tart`

---

## 3. Persist across reboots (launchd)

Install as a user LaunchAgent so the runner auto-starts when the VM boots and survives sleep/wake:

```bash
cd ~/actions-runner
./svc.sh install             # generates ~/Library/LaunchAgents/actions.runner.<owner>-<repo>.<name>.plist
./svc.sh start
./svc.sh status
```

Verify registration on GitHub: the runner should appear as `Idle` at
`https://github.com/madeye/meow-ios/settings/actions/runners`
within ~30 seconds of `svc.sh start`.

To tear down (e.g. VM rebuild, runner rename):

```bash
./svc.sh stop
./svc.sh uninstall
./config.sh remove --token <REMOVAL_TOKEN>   # fetched from same /new page as registration
```

---

## 4. Smoke-test via `workflow_dispatch`

```bash
gh workflow run nightly.yml --repo madeye/meow-ios
gh run watch
```

First-run signals to watch for:
- `tart pull` / `tart clone` steps complete (nested-virt works — the 2026-04-17 risk callout resolves positively).
- `scp` into the inner vphone VM succeeds (SSH keys provisioned inside the outer VM's `~/.ssh/`).
- The 5-check diagnostics gate ends with `** TEST SUCCEEDED **`.

If `tart pull` fails with a nested-virt error, that's the re-raise scenario team-lead flagged — escalate rather than workaround.

---

## 5. Token handling

- Registration tokens **expire in ~1 hour** and are single-use.
- Removal tokens are separate — fetched from the same `/settings/actions/runners/new` page.
- Neither token goes in the repo, in workflow files, or in any committed script. The only acceptable place is stdin / command-line argv during the one-time registration.
- If a token leaks, rotate it at `Settings → Actions → Runners → ⋯ → Remove` and re-register.
