# M4 — Config & Diag — kick-off note

Hand-off note for the fresh team that spawns after M2 + M3 close. Written while Dev was coding T4.8 (the last M2 task), so the new team isn't blind on day one. Mirrors the pattern of `docs/T4.8-SETTINGS-BRIEF.md`.

## What just shipped (M2 + M3 closed)

- **M2 (Basic UI):** app shell / Home / Subscriptions / **Settings** (T4.8, last M2 item)
- **M3 (Proxy & Realtime):** Connections (T4.5, PR #19 `abbf586`), Rules (T4.6, PR #25 `bb3599c`), Logs (T4.7, PR #26 `a75b951`)

UI-screen shape convention (carry forward): `ContentUnavailableView` empty state, `.safeAreaInset(edge: .top)` error banner, callsite-string accessibility identifiers in `<screen>.<group>.<detail>` dot-path form, `@State` in-view (no separate VM) unless there's a reason. See `App/Sources/Views/{ConnectionsView,RulesView,LogsView,SettingsView}.swift` for the authoritative pattern.

## M4 scope (per `docs/PROJECT_PLAN.md` §Milestone Summary)

| Task  | Screen                    | FFI deps                              | Other deps                     |
| ----- | ------------------------- | ------------------------------------- | ------------------------------ |
| T4.9  | YAML Editor               | `meow_engine_validate_config`         | T3.1 SwiftData, T4.3 Subs      |
| T4.10 | User-Facing Diagnostics   | `meow_engine_test_direct_tcp`, `_proxy_http`, `_dns` | T4.8 Settings (nav-stub site)  |
| T4.11 | Providers                 | `/providers` endpoint on MihomoAPI    | T3.4, T4.1                     |

All three are unblocked the moment T4.8 lands. No critical-path gating between them — pick the order.

### Suggested order

1. **T4.11 Providers** first — structurally simplest (fetch-and-render list, no FFI complexity). Good warm-up for the fresh team to re-absorb the house shape. Existing `App/Sources/Views/ProvidersView.swift` is a 46-LoC stub.
2. **T4.9 YAML Editor** — touches SwiftData persistence + one FFI call + `UIViewRepresentable` wrapping `UITextView`. Existing scaffold at `App/Sources/Views/YamlEditorView.swift` is ~107 LoC — read it before planning the diff.
3. **T4.10 Diagnostics** last — replaces the nav-stub placeholder T4.8 planted, uses three FFI entry points. Natural to land after the Settings page that points at it is fully stable.

Deviate from this order freely if the fresh PM sees a better line — this is a suggestion, not a mandate.

## Known gotchas + drift

### FFI symbol names (header is authority — see `feedback_header_symbol_authority.md` memory)

PROJECT_PLAN §T4.10 spells the diagnostics FFI as `meow_test_direct_tcp` / `meow_test_proxy_http` / `meow_test_dns_resolver`. **The header says otherwise:**

```c
// MeowCore/include/mihomo_core.h
int meow_engine_test_direct_tcp(const char *host, int port, int timeout_ms, int64_t *out_ms);
int meow_engine_test_proxy_http(const char *url, int timeout_ms, int *out_status, int64_t *out_ms);
int meow_engine_test_dns(const char *host, int timeout_ms, char *out, int out_cap);
```

Header is the authority. When T4.10 lands, update PROJECT_PLAN §T4.10 to match the actual symbol names (and note `test_dns` is a resolver-query with a char-buffer return, not a boolean pass/fail).

### T4.8 → T4.10 continuity

T4.8 plants a navigation stub (`settings.nav.diagnostics`) pointing at a `ContentUnavailableView("Coming in T4.10.")` placeholder. T4.10's first act is replacing that stub with the real diagnostics view. Identifier survives — the selector already works. Don't rename it.

### YAML editor: open decision (PROJECT_PLAN §Open Questions #3)

"`CodeEditView` Swift package (syntax highlighting) vs plain `UITextView`. Decide in M4." Still open. The existing scaffold uses `UITextView` via `UIViewRepresentable` — cheapest path. If the fresh team wants syntax highlighting, T4.9 is the decision point.

## Read these first (fresh PM orientation)

In this order, without burning time elsewhere first:

1. **This note** (`docs/M4-KICKOFF.md`) — you're here.
2. **`docs/PROJECT_PLAN.md`** §§T4.9, T4.10, T4.11, Dependency Graph, Milestone Summary, Open Questions.
3. **Memory feedback rules** — especially `feedback_pm_owns_waking_idle_agents.md`, `feedback_pause_means_pause.md`, `feedback_clear_team_context_at_milestone.md`, `feedback_local_ci_before_push.md`, `feedback_header_symbol_authority.md`.
4. **`docs/T4.8-SETTINGS-BRIEF.md`** — the brief-shape precedent. Use it as template for T4.9 / T4.10 / T4.11 briefs.
5. **`CLAUDE.md`** (project root) — non-code PR bypass rule + local-CI-before-push rule.
6. **`App/Sources/Views/{LogsView,SettingsView}.swift`** — latest authoritative pattern examples. The newer the reference, the closer it is to current conventions.

## Process notes (pre-existing rules — don't re-derive)

- Branch-per-task. Never commit to main. WIP-commit before cross-agent handoff. (Global CLAUDE.md + memory.)
- Local lint + tests before `git push`. (Project CLAUDE.md.)
- Non-code PRs: `gh pr merge --rebase --admin --delete-branch`. Code PRs: no `--admin`, wait for full CI.
- Task-state is not a wake signal. `in_progress` + idle owner ≠ "they'll pick it up" — PM dispatches explicit wake via SendMessage with concrete scope. (Memory: `feedback_pm_owns_waking_idle_agents.md`.)
- When team-lead says "pause until I confirm," pause. Don't ship the in-flight artifact. (Memory: `feedback_pause_means_pause.md`.)

## What this note does NOT cover

- Release / App Store / TestFlight work — that's M6.
- iOS 26 Liquid Glass UI polish pass — that's M5 (T5.1).
- T2.9 UDP non-DNS forwarding — M5 backlog item, gated on mihomo-rust upstream.
- The retired vphone-cli / nightly E2E infrastructure — see `project_meow_ios_v14_scope_collapse_2026_04_18.md` memory for the scope-collapse trail. Don't re-plumb it.
