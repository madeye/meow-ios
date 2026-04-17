# Self-hosted GitHub Actions Runner (Tart host)

**Status:** 2026-04-17 — runner not yet registered on `github.com/madeye/meow-ios`. `nightly.yml` references `runs-on: [self-hosted, macOS, apple-silicon, tart]`; until the runner registers with that label set, the job sits queued.

**Scope decision (2026-04-17 team-lead):** nightly E2E uses Tart as the vphone sandbox (no Mac mini fallback). The runner itself and the fixture servers live on the **outer runner host**; the Tart guest only runs vphone-cli + SSH + SIP-disabled macOS. See [`TEST_FIXTURES.md §5`](./TEST_FIXTURES.md) for the wiring.

This file is the manual setup runbook the user follows once per runner-host build to register a self-hosted runner.

---

## 1. Prereqs on the runner host (not inside the Tart VM)

The runner and the fixture servers both live on the **outer macOS host** that boots Tart. The Tart guest only runs vphone-cli + SSH + SIP-disabled macOS; the virtual iPhone inside it reaches fixtures on the outer host via the Tart bridge IP (resolved inside `scripts/test-e2e-ios.sh` from `VPHONE_HOST`).

Run on the runner host:

```bash
# Fixture binaries (shadowsocks-rust / trojan-go / xray / wireguard /
# hysteria / tuic-server) — idempotent; installs only what's missing.
bash scripts/provision-tart-fixtures.sh

# Virt + build tools the nightly workflow invokes on the host
brew install tart xcodegen xcbeautify

# Self-hosted runner bits
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL -o actions-runner-osx-arm64.tar.gz \
  https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64-2.322.0.tar.gz
tar xzf actions-runner-osx-arm64.tar.gz
```

SIP status matters **inside the Tart guest**, not on the host: vphone-cli needs SIP-disabled macOS, and that constraint is satisfied by `bld-e2e-base` itself (see [`TEST_STRATEGY.md §7`](./TEST_STRATEGY.md)). The host can keep SIP enabled.

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
- `tart clone` from the local `bld-e2e-base` image completes (nested-virt works — the 2026-04-17 risk callout resolves positively). No `tart pull` step: the workflow runs only on a host that already has the base image locally (see `TEST_FIXTURES.md §5`).
- `scp` into the inner vphone VM succeeds (SSH keys provisioned inside the outer VM's `~/.ssh/`).
- The 5-check diagnostics gate ends with `** TEST SUCCEEDED **`.

If `tart clone` fails (`bld-e2e-base` missing, nested-virt disabled, etc.), that's the re-raise scenario team-lead flagged — escalate rather than workaround.

---

## 5. Token handling

- Registration tokens **expire in ~1 hour** and are single-use.
- Removal tokens are separate — fetched from the same `/settings/actions/runners/new` page.
- Neither token goes in the repo, in workflow files, or in any committed script. The only acceptable place is stdin / command-line argv during the one-time registration.
- If a token leaks, rotate it at `Settings → Actions → Runners → ⋯ → Remove` and re-register.
