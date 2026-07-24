# lwip PCB double-free — wedge/crash root cause, fix, and follow-ups

**Date:** 2026-07-23/24 (incident + investigation)
**Investigator:** Kimi Code CLI driven by gang
**Status:** FIX ON DEVICE, pending verification + upstream. This file is the
checklist to resume from.
**Related:** `INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md`,
`INVESTIGATION-2026-07-24-dns-udp-blackhole-after-network-switch.md`
(the "连不上自愈" episodes turned out to be a DIFFERENT issue — DNS/UDP
after network switch — documented there, not here)

## TL;DR

lwip had paths that free a TCP pcb **without notifying the application**
(err callback). The Rust tun2socks binding keeps the raw pcb in its
stream object and calls `tcp_close`/`tcp_abort` from `Drop`, guarded by a
`ctx.errored` flag that only the err callback sets. A silently-freed pcb
therefore got `tcp_close`d again from `Drop` → hit the CLOSED branch
(`local_port == 0` → no list removal) → **`tcp_free` twice** → memp
free-list corruption → the same block handed out by two `tcp_alloc`s →
duplicate `TCP_REG` → PCB list cycle (wedged `tcp_input` walk holding
`LWIP_MUTEX` = 断流) or bad-state node (assert crash). Fix: fire the err
callback on those two free paths. **Zero crashes since the fix
(2026-07-24 ~02:00), previously ~15/day.**

## Symptoms (both were the same root cause)

1. **Wedge ("断流"):** VPN shows connected, zero traffic, watchdog often
   unable to recover. Mechanism: duplicate `TCP_REG` creates a list
   cycle; the next `tcp_input` demux walk spins forever holding
   `LWIP_MUTEX`; every lwip-touching thread freezes.
2. **Crashes:** `SIGABRT` on `meow-tun2socks` thread in
   `tcp_input`/`tcp_pcbs_sane`. 15 reports on 2026-07-23, interval
   16–51 min. These appeared once the diagnostic build turned the silent
   spin into a bounded-walk abort.

## Root-cause chain (each link has direct evidence)

1. Rust `TcpStreamImpl::drop` (lwip fork `rust/tcp_stream_impl.rs:206`)
   calls `tcp_abort` or `tcp_close` on the raw pcb unless
   `ctx.errored` (set only by `tcp_err_cb`).
2. **Silent free path 1:** `tcp_input_delayed_close` (tcp_in.c:616)
   skipped `TCP_EVENT_ERR(..., ERR_CLSD)` when `TF_RXCLOSED` was set.
   **Silent free path 2:** `tcp_slowtmr` TIME_WAIT reap (tcp.c tw loop)
   fired no callback at all. (FIN_WAIT_2 slowtmr reap on the *active*
   list does fire ERR — that path was fine.)
3. `Drop` on a silently-freed pcb: stale memory reads `state=CLOSED`,
   `local_port=0` (zeroed by `tcp_pcb_remove` in step 2) →
   `tcp_close_shutdown` CLOSED case skips `TCP_RMV` → `tcp_free` again.
4. Double free → block on memp free list twice → two `tcp_alloc`s return
   it → two owners → duplicate `TCP_REG` / active↔tw list splice.
5. List corruption detonates minutes later in an unrelated `tcp_input`
   walk — which is why crash stacks never pointed at the cause.

### Key evidence

- 2026-07-24 00:43 crash ring: pcb `0x103d39ec0` freed **twice**
  (`f? st=0 lp=0 rp=52769` ×2, no intervening `GA`) → later double-`GA` →
  `TCP_REG: already registered` assert at `tcp_in.c:720`
  (`tcp_listen_input`).
- 2026-07-24 01:48 crash: tw list contained a SYN_RCVD node splicing
  into the whole active list; pcb `0x1061021e8` history shows the second
  free with **`caller=0x1053a05d0` → `tcp_close_shutdown`**, first free
  via `tcp_input_delayed_close`. Caller tagging (`__builtin_return_address`
  in the diag ring) is what nailed the sites.

## The fix (currently ONLY in the local diag fork `/Users/gang/proj/lwip-diag`)

1. `old-src/core/tcp_in.c` `tcp_input_delayed_close`: **always** fire
   `TCP_EVENT_ERR(..., ERR_CLSD)` — removed the `TF_RXCLOSED` skip.
2. `old-src/core/tcp.c` slowtmr TIME_WAIT reap: save `errf`/`callback_arg`
   and fire `TCP_EVENT_ERR(..., ERR_ABRT)` after `tcp_free` (mirrors the
   active-list reap). No-op for pcbs whose `Drop` already cleared `errf`.

Both are safe: the Rust `tcp_err_cb` only marks its own context, never
touches the pcb.

## Follow-up checklist

Verification:
- [ ] **Zero new `PacketTunnel-*.ips`** (Settings → Privacy & Security →
  Analytics → Analytics Data) for ~3 days of heavy use. Was ~15/day.
  If one appears: pull it + `/tmp/meow-pt-full.log`-style capture; the
  diag build still dumps list walks + lifecycle ring + callers on any
  assert, so a residual silent-free path will name itself.

Upstream & restore (order matters):
- [ ] Extract the two fixes (and only those) from `lwip-diag` into a
  commit on a fork of `madeye/lwip`; PR upstream. The fork also contains
  DIAG-ONLY code (ring, cycle abort, `TCP_DEBUG_PCB_LISTS`,
  `meow_dump_evidence`, caller logging) that must NOT go upstream.
- [ ] `core/rust/meow-ios-ffi/Cargo.toml`: repoint `[patch.crates-io]`
  lwip to the upstream rev (currently `path = "/Users/gang/proj/lwip-diag"`
  — marked DO NOT COMMIT), restore `strip = "symbols"` (currently
  `false` for self-symbolicating .ips).
- [ ] Decide the fate of the diagnostics: keep `TCP_DEBUG_PCB_LISTS` +
  bounded sanity walk in dev builds as a tripwire, or drop entirely.
  Bounded `tcp_pcbs_sane` walk + assert→os_log routing are cheap and
  turn silent corruption into loud crashes; worth considering for dev.
- [ ] Working tree cleanup: `meow-ios.xcodeproj/project.pbxproj` has
  local `DEVELOPMENT_TEAM` + xcodegen drift — do NOT commit; regenerate
  via `scripts/generate-xcodeproj.sh`. `MeowCore/include/meow_core.h`
  comment tweaks are separately committable if wanted.
- [ ] Consider upstreaming to `ssrlive/lwip` (the original upstream per
  the Cargo.toml comment) if madeye's fork accepts the patch first.

Not action items (settled):
- **Watchdog stays.** Reviewed 2026-07-24: lock-free heartbeat, ingress
  gating, non-blocking ingest (can't be taken hostage), bounded teardown
  → deterministic `cancelTunnelWithError:` escalation. Clean. The
  "ingress-thread blind spot" feared during the session was a
  measurement artifact (awk field bug), not a real gap.
- Deferred to the DNS doc: resolver UDP→TCP/DoH fallback; QUIC block
  ICMP-unreachable instead of silent drop.

## Evidence locations (ephemeral!)

`/tmp/meow-crashlogs/` (15 .ips), `/tmp/meow-pt-full.log` (full engine
log with the v3/v4 assert dumps). `/tmp` does not survive reboots — the
essential excerpts are inline above. The exported tunnel log lives at
`~/Documents/meow-tunnel-20260724-203303.log` (covers the DNS episode,
not the crashes).
