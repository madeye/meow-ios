# TCP flow matching DIRECT rule — occasional hang ("断流")

**Date:** 2026-05-18
**Investigator:** Claude Opus 4.7 driven by max.c.lv@gmail.com
**Tool chain:** Source-only audit of the live `claude/fix-tcp-flow-disconnect-ezNma`
branch + cross-reference against `meow-rs` v0.7.6 and the patched
`netstack-smoltcp` (`feat/aggressive-recycle`). No new device reproduction
was run for this pass.

## TL;DR

Symptom (operator-reported, not a regression — predates the current branch
by months): TCP flows matched to the `DIRECT` outbound occasionally
**hang** on the device. The smoltcp side completes the 3-way handshake
with the app, but no upstream bytes ever appear in the egress, across all
DIRECT destinations roughly equally and with no obvious trigger (no path
change, no tunnel restart, no traffic burst).

This shape matches **a stalled outbound dial inside `meow-proxy`'s
`DirectAdapter::dial_tcp`**, which awaits `tokio::net::TcpStream::connect`
with **no timeout at any layer** of the pipeline:

* `meow-proxy/src/direct.rs::DirectAdapter::dial_tcp` — bare `.await` on
  `connect_with_mark` (the `routing_mark` arm is `#[cfg(target_os =
  "linux")]`; iOS falls through to plain `TcpStream::connect`).
* `meow-tunnel/src/tcp.rs::handle_tcp` — bare `.await` on
  `proxy.dial_tcp(&metadata)`.
* `meow-ios-ffi/src/tun2socks.rs::dispatch_tcp` — bare `.await` on
  `meow_tunnel::tcp::handle_tcp` (plus the post-FIN 250 ms grace added
  in `5685553`, which is post-connect and does not bound the dial).

A stalled dial holds its `tcp_accept_sem` permit indefinitely and the
flow's `last_active_ms` stays whatever the IdleTracking wrapper last
stamped — but on a stalled dial **the wrapper's `touch()` never runs
because `copy_bidirectional_buf` is never entered**. The 30 s idle
sweeper (`TCP_IDLE_SECS = 30`, `tun2socks.rs:145`) does walk the registry
on schedule, but it compares against the freshness-on-create stamp from
the accept loop (`now_ms()` at `tun2socks.rs:464`); each app-side
retransmit (TLS ClientHello, packet retries) goes through netstack but
**not through the IdleTracking instance** — IdleTracking sits on the
meow-rs side of the relay, downstream of `handle_tcp`. So as long as the
relay never starts, the IdleTracking timestamp never advances *and* never
gets re-stamped by the retransmits — the flow does eventually get reaped
30 s after accept, but from the app's perspective that 30 s is a
black-hole hang on every DIRECT-routed connection that draws the bad
card.

Why DIRECT specifically and not proxied with the same code path:

* Proxied flows funnel through a small set of proxy-server IPs. iOS's
  reachability cache for those IPs stays hot, and `TcpStream::connect`
  almost always succeeds quickly against a known-good endpoint.
* DIRECT fans out across every destination IP that matches the rule
  (CN PoPs, mixed CDN edges, occasionally LAN). Per-destination connect
  hang rate is small but non-zero, and aggregated across hundreds of
  DIRECT flows per session it surfaces as "occasional disconnect."

## What the symptom narrows to

Operator clarifications (`AskUserQuestion`, 2026-05-18):

| Question | Answer |
| --- | --- |
| How does the disconnect manifest? | Hang / no response (3WHS done, no bytes flow) |
| When does it happen? | Random / steady state — no obvious trigger |
| Which destinations? | All DIRECT-rule destinations roughly equally |

This combination rules out three plausible-looking candidates:

* **Mid-flow truncation from the 250 ms post-FIN grace (`5685553`,
  `tun2socks.rs:771-785`).** That would produce truncated responses (RST
  visible to app), not a 3WHS-completes-then-silence hang. Also a recent
  regression, while the issue is long-standing.
* **Path-change or tunnel-restart races.** No correlation with path
  changes in the user's report.
* **Stale fake-IP after pool eviction (`pre_handle_metadata` leaves
  `dst_ip = 28.x.x.x` when reverse-lookup fails; `DirectAdapter::
  resolve_target` step 1 dials `dst_ip` directly without re-validating).**
  Would correlate with specific hosts whose entries were evicted, not
  *all* DIRECT destinations equally. The meow-rs resolver's fake-IP CIDR
  is `28.0.0.0/8` (16M IPs); pool wraparound is essentially impossible
  under normal traffic.

## Path trace (current code, post-5685553 baseline)

Annotated control flow for a DIRECT-routed flow, with the line numbers
each step lives at:

1. `MWTunnelEngine.readNextPackets` (`PacketTunnel/Sources/MWTunnelEngine.m:154`)
   reads IP frames off `NEPacketTunnelFlow.readPacketObjects` and pushes
   them into `meow_tun_ingest`.
2. `tun2socks::ingest` (`tun2socks.rs:332`) `try_send`s into
   `ingress_rx` (bounded mpsc, depth 256; full → drop with a throttled
   warn).
3. `run_tun2socks`'s ingress loop (`tun2socks.rs:569`) demuxes UDP/53 vs.
   the rest; non-DNS frames go into `stack_ingress_tx` which the
   single-threaded `stack_handle` (`tun2socks.rs:393-426`) forwards to
   smoltcp.
4. smoltcp completes 3WHS, surfaces the new TCP stream on
   `tcp_listener.next()` (`tun2socks.rs:430`).
5. `tcp_accept_handle` (`tun2socks.rs:429`) awaits a permit from
   `tcp_accept_sem` (cap 32 by default, `TCP_ACCEPT_CAP_DEFAULT = 32`,
   `tun2socks.rs:119`).
6. With permit in hand it spawns `dispatch_tcp` and inserts the flow
   into `tcp_flows()`'s `FlowRecord` with `last_active_ms = now_ms()`
   (`tun2socks.rs:463-480`).
7. `dispatch_tcp` (`tun2socks.rs:712`) builds `Metadata` with
   `dst_ip = Some(dst.ip())`, `host = ""`, wraps the netstack stream in
   `IdleTracking`, and awaits `meow_tunnel::tcp::handle_tcp`
   (`tun2socks.rs:769`).
8. `handle_tcp` (meow-tunnel `src/tcp.rs`) calls `pre_handle_metadata`
   (reverses fake-IP → host), `pre_resolve`, `resolve_proxy` (rule
   match), then `proxy.dial_tcp(&metadata)`.
9. `DirectAdapter::dial_tcp` (meow-proxy `src/direct.rs`) calls
   `resolve_target` (which short-circuits on `metadata.dst_ip` if still
   set, otherwise calls `resolver.resolve_ip(&host)`), then
   `connect_with_mark(dest, self.routing_mark)`.
10. `connect_with_mark` on iOS is plain `tokio::net::TcpStream::connect`
    — **no timeout**. iOS's auto-bypass routes the socket via the
    physical interface (en0/pdp_ip0), but `connect()` can hang
    indefinitely under iOS reachability-cache or scoped-routing
    transient states (Wi-Fi assoc churn, IPv6 RA churn, post-wake route
    reassessment).
11. While `dial_tcp` is hung, `copy_bidirectional_buf` is never reached
    → `IdleTracking::poll_read`/`poll_write` are never called →
    `state.last_active_ms` stays at its create-time value.
12. The app retransmits its initial payload (TLS ClientHello, etc.).
    These reach smoltcp (which ACKs them via its receive window) but
    never propagate to `IdleTracking` because no one is reading from
    the netstack stream yet.
13. 30 s after accept, the idle sweeper (`tun2socks.rs:218`) evicts the
    flow via `rec.abort.abort()`. The aborted task drops the netstack
    `TcpStream`, the patched smoltcp's aggressive-recycle handler sees
    `send_state != Normal` and calls `socket.abort()` → RST to the app.

So the app's observable timeline:
- `t=0`: SYN out, SYN-ACK back (smoltcp). Connection established.
- `t=0+ε`: app sends ClientHello / first payload. Stack ACKs. App waits.
- `t=30 s`: app sees RST. Connection torn down. App reports timeout /
  disconnect.

Subjective duration: "page hangs for ~30 s, then errors out." Matches
the user-side `断流` description.

## Why the existing memory-pressure backstops don't catch this

* `tcp_accept_sem` (cap 32) bounds *in-flight* dispatch tasks. A stuck
  dial holds a permit for the entire 30 s before the sweeper reaps it.
  At a hang rate of, say, 1% of DIRECT dials, on a session opening
  100 DIRECT flows/min you accrete one stuck flow every minute. Permit
  depletion is gradual but real; once permits saturate, new DIRECT
  accepts wait behind the sweeper's 10 s tick interval before fresh
  permits free up.
* `TCP_WATCHDOG_THRESHOLD = 256` (`tun2socks.rs:179`) is far above the
  32-permit ceiling, so the watchdog never fires from this mode of
  accumulation alone.
* The 250 ms post-FIN cut (`5685553`) only triggers on local-EOF, which
  the app *doesn't* send during the hang — it's still waiting for a
  response.

## Why `xhs_e2e.rs` (now-deleted) is the right reproduction shape

`5265b30 test(diag): rust-only xiaohongshu.com end-to-end repro` added a
self-contained harness that drove the FFI surface against a Rust egress
sink (no Xcode, no device). The harness:

1. Synthesized an in-TUN DNS A query.
2. Synthesized a TCP SYN to the resolved IP, verified the netstack
   returned a SYN-ACK.
3. Completed the 3WHS in-test and synthesized a real TLS ClientHello
   with `SNI=www.xiaohongshu.com`.
4. Drained the egress channel for 10 s waiting for any IPv4+TCP segment
   from `resolved_ip:443` carrying a payload.

The comment that survived in the test source — "NO upstream data within
10s — the engine either failed to dial the real host, the rule chain
dropped the flow, or the upstream silently held the connection. This is
the symptom that maps directly to 'page hangs' on-device." — is the same
shape as today's report.

The harness was deleted in `a8351c5` ("delegate fake-IP DNS to meow's
resolver in-process") along with the FFI's own fake-IP module. The
**DNS-side** findings of the diagnostic were addressed in `37aa64a`
(CN-only nameserver pool) and `a8351c5` (resolver in meow-rs). The
**relay-side** finding ("dial succeeded but no bytes flowed") was never
specifically attributed — the diagnostic listed three candidates and
moved on. The current investigation re-opens that question and points
at the dial itself rather than the relay.

## Rejected hypotheses (kept for the next investigator)

These were considered and ruled out by the operator-reported symptom
combination above.

1. **The 250 ms post-FIN grace in `dispatch_tcp` (commit `5685553`,
   `tun2socks.rs:771-785`).** Would produce mid-flow truncation, not a
   hang; would surface as RST mid-response. Long-standing nature of the
   bug eliminates this anyway.
2. **Aggressive smoltcp recycle (`feat/aggressive-recycle` fork) firing
   `socket.abort()` mid-flow.** Same shape as (1), and same timeline
   exclusion.
3. **Fake-IP pool wrap evicting reverse-mapping entries.** Would target
   specific hostnames whose entries were evicted (sticky to those
   destinations), not all DIRECT destinations equally. CIDR is 28/8.
4. **Egress channel saturation (`tun2socks.rs:407-415`, `try_send` →
   drop on full).** Would correlate with traffic bursts ("steady state"
   eliminates this) and would affect proxied flows too. The
   `EGRESS_DROP_LOG_LAST_MS` throttled warn would also have a paper
   trail.
5. **Path-change race tied to `5685553`'s `meow_tun_close_all_tcp_flows`.**
   No correlation with path changes per operator report.
6. **Tokio runtime starvation (`worker_threads = 2`,
   `lib.rs:54`).** Plausible under heavy CPU load, but the steady-state
   symptom and rate-independent reporting argue against it. Worth
   measuring directly (worker-thread blocking time) before ruling out
   for good.

## Proposed solutions — future improvement

Three tiers. (1) is the smallest defensive fix and lives in the FFI;
(2) is the proper upstream fix; (3) is the diagnostic harness that
would have caught this without needing operator reports.

### 1. FFI-side dial deadline in `dispatch_tcp`

Wrap `meow_tunnel::tcp::handle_tcp` in a first-byte deadline. If
`state.last_active_ms` (touched on the first successful `poll_read` /
`poll_write` of the netstack stream by `IdleTracking`) has not advanced
within N seconds of accept, abort the future. The relay's first
successful poll happens only after `dial_tcp` returns, so this
effectively bounds the dial.

Sketch (in `dispatch_tcp` after the existing `let local_eof = …`):

```rust
let accepted_at = now_ms();
let dial_deadline_ms = DIAL_DEADLINE.load(Ordering::Relaxed); // e.g. 10_000

let fut = meow_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata);
tokio::pin!(fut);

let dial_watchdog = async {
    loop {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if state.last_active_ms.load(Ordering::Relaxed) > accepted_at {
            return; // relay started — dial succeeded
        }
        if now_ms().saturating_sub(accepted_at) >= dial_deadline_ms {
            return; // exceeded — caller should drop the future
        }
    }
};
tokio::pin!(dial_watchdog);

tokio::select! {
    biased;
    _ = &mut fut => return,
    _ = local_eof.notified() => {
        // existing 250 ms post-FIN logic
    }
    _ = &mut dial_watchdog => {
        if state.last_active_ms.load(Ordering::Relaxed) <= accepted_at {
            warn!(
                "tun2socks: dial deadline exceeded for {} -> {} after {} ms",
                src, dst, dial_deadline_ms,
            );
            return; // drop fut → meow-rs session cleanup, accept_sem permit released
        }
    }
}
```

Threshold: 10 s is a reasonable starting point — Mobile Safari's
request-timeout floor is ~12 s and iOS's BSD-style SYN retransmit grid
gives up around 75 s. A user-tunable hook (`meow_tun_set_dial_deadline_
ms`, analogous to `set_accept_cap`) leaves headroom for high-latency
cellular environments without recompiling.

Pros:
- Lives entirely in the FFI; no upstream `meow-rs` change required.
- Releases the `tcp_accept_sem` permit promptly so the 32-cap doesn't
  pile up stuck flows.
- App sees RST in 10 s instead of 30 s — recoverable from the app's
  retry loop (most apps re-dial on RST/timeout within a few seconds).

Cons:
- Cold-start cellular handshakes against geographically distant CN PoPs
  can legitimately take ~5-8 s on first connect. 10 s leaves narrow
  headroom; pick the threshold from a real-device latency sample
  before locking it in.
- Bandaid: doesn't fix the underlying `TcpStream::connect` indefinite
  hang, just reaps it faster.

### 2. Upstream: connect timeout in `meow-proxy::DirectAdapter`

The proper fix is in `madeye/meow-rs`. Two adjacent options:

a. **Wrap `connect_with_mark` in `tokio::time::timeout`.** Simplest
   change; flows back to all downstream consumers of the crate, not
   just the iOS FFI. Threshold tunable via `Adapter` config (meow's
   YAML `connect-timeout:` field already exists on some adapter types
   — extending it to `DirectAdapter` is the natural slot).

b. **Use `TcpSocket::connect` with explicit interface binding
   (`IP_BOUND_IF` / `IPV6_BOUND_IF`) on Apple platforms** to pin the
   outbound to the physical interface explicitly rather than relying
   on iOS's auto-bypass. This is what other iOS VPN clients
   (Surge, Quantumult X, Loon, sing-box on iOS) do — they all set
   `IP_BOUND_IF` to the primary physical interface index, retrieved
   from `nw_path_t.primaryInterface` or `getifaddrs()`.

   Combined with (a), this addresses both the symptom (timeout bounds
   the hang) and the suspected root cause (auto-bypass not engaging
   reliably under iOS routing transients).

   The interface index needs to be re-read on every path change and
   passed from Swift down through the FFI into meow-rs. Plumbing-heavy
   but mechanical.

Pros:
- Fixes the issue at the source for all meow-rs consumers.
- (b) eliminates the iOS routing-cache failure mode entirely rather
  than reaping it.

Cons:
- Requires an upstream PR + version bump. Multi-week lag.
- (b) is a non-trivial cross-cutting change (Swift path monitor →
  IPC → FFI → meow-rs) that touches roughly six files.

### 3. Diagnostic harness — restore `xhs_e2e.rs` as a regression repro

The `xhs_e2e.rs` test was the right shape but was deleted alongside the
FFI-side fake-IP module in `a8351c5`. Recreating it (or a successor
under the now-meow-owned DNS path) gives:

- A repeatable Rust-only reproduction of "DNS resolves, SYN-ACK comes
  back, no upstream data within Ns" without needing a phone in hand.
- A cargo-test gate that fails when a future change regresses the
  dial-timeout backstop.
- A platform for instrumented attribution: tracing-subscriber +
  `RUST_LOG=meow_proxy::direct=trace` should expose exactly which
  `connect()` hangs (logging dest IP + elapsed before timeout fires).

Specifically:

* The successor harness should drive against an arbitrary DIRECT
  destination (not just `xhs.com`) — parameterize the host so the same
  test can probe any user-reported flaky destination.
* It should assert a *positive* outcome under solution (1) above:
  given a synthesized SYN against an unreachable destination
  (`192.0.2.1`, TEST-NET-1, which black-holes), the egress should
  carry a RST within `dial_deadline_ms + 1 s`. Without the fix the
  test hangs for the test-runner's wall-clock cap.
* It should also be wired into CI's Rust matrix (the existing
  `cargo test` job in `.github/workflows/ci.yml`), gated to run only
  when network egress is available (existing `xhs_e2e` had a
  skip-on-no-internet escape hatch — preserve it).

## Priority ordering

If only one thing happens before the next TestFlight cut, do **(1)**.
It is small, lives entirely in the FFI, and the worst-case behavior
shift is "app sees RST in 10 s instead of 30 s on the flows that were
already hanging." The accumulation-of-stuck-flows path is closed
immediately.

(2a) should be filed against `madeye/meow-rs` as soon as (1) lands
— the upstream timeout is the durable fix that benefits all
consumers, and the FFI deadline becomes a defense-in-depth backstop
rather than the only line.

(2b) is the architectural fix and should be evaluated against the
operational data the (1) warn logs produce. If `warn!("tun2socks:
dial deadline exceeded …")` shows clear interface-correlation patterns
(e.g., always after a Wi-Fi roam), the case for the explicit
`IP_BOUND_IF` plumbing strengthens. If the distribution is uniform
across known-good interfaces, the auto-bypass is fine and (2a) alone
is sufficient.

(3) is the lowest-cost insurance against this whole class of bugs and
should land independent of (1)/(2)'s timing.

## Open questions for the next pass

* **Are there logged occurrences of the egress-drop warn
  (`EGRESS_DROP_LOG_LAST_MS`)** on devices that report the disconnect?
  If yes, hypothesis (4) above is back on the table and the symptom
  might be a mix of two failure modes.
* **Tokio worker-thread saturation under steady state**: a quick
  `tokio-console` or `tokio::runtime::Handle::metrics()` sample from
  a long-running session would settle whether the 2-worker runtime is
  ever wedged on blocking work. If a thread blocks (e.g., on a
  synchronous DNS call somewhere in meow-rs), every async task is
  stalled — which would also present as "DIRECT flow hangs" but with
  proxied flows hanging too. Worth a 30-minute device-side capture
  before assuming the hypothesis above is exhaustive.
* **Does `pre_resolve` (meow-tunnel, called inside `handle_tcp`)
  ever block synchronously?** If `resolver.resolve_ip` is invoked
  with the wrong runtime context (e.g., inside a `block_on` somewhere
  upstream), it could be the actual stall site rather than `connect`.
  Verifiable by instrumenting `handle_tcp` with span timestamps
  before/after `pre_resolve` and before/after `dial_tcp`.
