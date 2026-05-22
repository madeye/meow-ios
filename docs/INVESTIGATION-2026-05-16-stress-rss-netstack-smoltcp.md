# RSS-growth attribution — netstack-smoltcp TCP listener closures

**Date:** 2026-05-16
**Investigator:** Claude Opus 4.7 driven by max.c.lv@gmail.com
**Tool chain:** `macos-utun-harness` (added `dhat-heap` feature gate) running inside the
`meow-ios-dev` Tart VM. Allocation profile via `dhat-rs` v0.3.

## TL;DR

The previously-tracked **+0.14 MiB/s** linear RSS growth during sustained
TCP-connection churn is **not** caused by meow internals (resolver cache,
NAT entries, rule stats) as previously assumed. It is overwhelmingly
caused by **`netstack_smoltcp::tcp::TcpListenerRunner::create`'s
per-connection closure state not being released when flows close**.
The crate at the boundary (downstream of the FFI, upstream of
`meow-tunnel`) is the right place to fix it.

## Stress profile

* Harness: `core/rust/macos-utun-harness/target/aarch64-apple-darwin/release/meow-utun`
  built with `--features dhat-heap`.
* Config: `/Users/mlv/tmp/mihomo-linux-clippy/config-sub.yaml` (the
  developer's real subscription; 8,201 lines, full SS/Trojan/VLESS upstream
  set + CN-bypass rules).
* Stress generator (built into the harness): 32 concurrent TCP
  connections to `github.com:443`, 200 ms hold per connection, 5-minute
  duration. Real packets routed through the in-VM `utun4` → engine →
  upstream proxy.
* Tart VM `meow-ios-dev`, macOS 25.4.0.

## RSS curve (uninstrumented, 20-minute run)

| `t (s)` | `rss (MiB)` | `peak (MiB)` | Phase |
| ------: | ----------: | -----------: | ----- |
|       0 |       35.55 |        35.55 | Cold start |
|     130 |      121.48 |       122.72 | Warmup peak (32-conn burst + cache fill) |
|     260 |      122.44 |       122.72 | Plateau ≈ 122 MiB |
|     390 |   **60.66** |       123.94 | Allocator release (-63 MiB) |
|     650 |       99.59 |       123.94 | Linear regrowth begins |
|    1040 |      165.89 |       165.89 | Surpasses prior peak |
|    1290 |      182.38 |       182.38 | New peak |

* Steady-state slope (linear fit, t=400→1230s, n=84):
  **+0.146 MiB/s** (≈ +8.79 MiB/min, +500 MiB/hour extrapolated).
  Matches the prior characterization within noise.
* Allocator burst-then-release at t≈390s is healthy (system arena
  reclaimed); the post-recovery linear growth is what matters.

## dhat attribution (5-minute instrumented run)

Note: dhat-instrumented runs cannot match the uninstrumented connection
rate (instrumentation overhead suffocates the stress loader and inflates
RSS to ~850 MiB). The **ranking** of allocation sites is what's
load-bearing here, not the absolute numbers; dhat's "exit-live" counter
includes allocations the system allocator has freed but dhat hasn't
observed `free()` for at profiler-drop time.

### Top retained-at-exit allocations (aggregated by topmost app frame)

| Rank | Exit-live | Blocks | Site |
| ---: | --------: | -----: | ---- |
|    1 | **11.07 GiB** | **43,216** | **`netstack_smoltcp::tcp::TcpListenerRunner::create::{{closure}}`** |
|    2 |   70.3 MiB |      4 | `hashbrown::RawTable::with_capacity_in` (pre-sized tables) |
|    3 |    2.6 MiB |  3,255 | `hashbrown::RawTable::reserve_rehash` (NAT/conntrack regrowth) |
|    4 |    1.4 MiB |    140 | `tokio::runtime::task::core::Cell::new` (spawned task headers) |
|    5 |    864 KiB |    216 | `tungstenite::buffer::ReadBuffer::with_capacity` (WS framer) |
|    6 |    641 KiB |    268 | `tokio::sync::mpsc::list::Tx::push` (queue depth) |
|    7 |    615 KiB | 39,378 | `iprange::IpTrie::insert` (CN-IP trie baseline — not growing) |
|    8 |    444 KiB |    111 | `rustls::DeframerVecBuffer::read` (per-conn TLS deframer) |
|    9 |    308 KiB |  6,574 | `meow_rules::parser::parse_rule` (rule parse — baseline) |
|   10 |    252 KiB |    108 | `meow_transport::ws::WsLayer::connect` (WS handshake state) |

Site #1 dominates by **2-3 orders of magnitude**. At
roughly 4 retained closure-allocations per accepted connection (43k
live ÷ ~10.6k connections opened during the run), every connection
appears to leave per-flow state behind even after FIN/RST.

### Top live-at-peak allocations

Same ordering as exit-live; site #1 grows from 11.07 GiB exit-live →
12.63 GiB peak-live (50,476 blocks), confirming the leak is steady
rather than burst-driven.

## Hypothesis

`netstack_smoltcp::tcp::TcpListenerRunner::create` is the routine that
spawns the per-connection tokio handler. The two nested `{{closure}}`
levels in the symbol point at the closure that captures the
per-connection state (smoltcp socket handle, ingress/egress channels,
shutdown signaler). One of the following is likely:

1. The `JoinHandle` of the spawned task is dropped/forgotten, but the
   task's local state references a long-lived structure (e.g. the
   listener's accepted-connections map) that retains the closure-captured
   variables.
2. The listener-level shared state keeps a per-connection record that
   isn't pruned on connection close, only on listener shutdown — so the
   structure grows monotonically for the listener's lifetime.
3. A drop chain has been broken by a recent `meow-rs` change (the
   crate is pulled as a cargo-git dep at `v0.7.3` / `0f182f4b`; the
   `netstack_smoltcp` dep is at `v0.2.1`).

The CN-IP trie (#7) and rule parser (#9) being explicitly **not**
growing rules out the prior "rule stats" attribution. NAT regrowth
(#3) is only 2.6 MiB — small. Resolver cache doesn't even appear in
the top 20.

## On the 50 MB NE jetsam cap

* macOS process baseline ≈ 35 MiB includes ~19 MiB of harness binary +
  libc/dyld not present on the iOS NE process.
* After subtracting macOS-only overhead, engine-attributable resident
  hits ≈ 163 MiB at t=1290s, projected onto NE → **3.3× over cap**
  under matching stress.
* The PR #131 / v1.3.0 release note's "−76% peak FFI RSS in stress
  tests" was almost certainly measured under lighter stress params; the
  parameters here (32 conn × 150/s × 21 min) blow through that.

## Suggested follow-ups

1. **iOS-device Instruments allocations capture.** macos-harness
   measurements bound the engine's behavior but cannot substitute for
   the actual NE process under iOS's allocator (libmalloc) and jetsam
   accounting. Especially important given the negative result on
   netstack-smoltcp below — the next attribution attempt needs a tool
   that reports retention by physical page, not by un-freed-allocation
   count.
2. **Investigate the 70 MiB hashbrown baseline** (site #2). Four tables
   pre-sized to ~17.5 MiB each is anomalous and could be trimmed
   independently of the leak fix.
3. **Profile meow-tunnel's connection lifecycle** rather than
   netstack-smoltcp: rustls per-conn state, tokio mpsc backlog,
   NAT/conn-tracking eviction on FIN/RST. The patched-build experiment
   below points away from netstack-smoltcp as the source.

## Update — 2026-05-16 (negative result on the netstack-smoltcp patch)

Tested the netstack-smoltcp hypothesis from the section above by
fork-pinning the crate with two changes:

* `DEFAULT_TCP_*_BUFFER_SIZE`: `0x3FFF * 20` → `0x3FFF * 4` (320 KB →
  64 KB per direction; expected 5× per-flow buffer reduction).
* `socket.set_timeout`: 7200 s → 60 s (expected ~12× reduction in
  TIME_WAIT residency).

Patch lived on the `meow-ios/buf-and-timeout-trim` branch of the fork
and was wired in via `[patch.crates-io]` in
`core/rust/meow-ios-ffi/Cargo.toml`. The Rust workspace rebuilt
cleanly; cargo confirmed the patched crate was in the dependency tree
(`otool` and the git-checkout source both verified the patched
constants made it into the binary).

Stress profile identical to the baseline run (32 conn × 200 ms hold,
github.com:443, dev config, Tart VM).

### Result: the patch made things 3.4× worse

| | Unpatched (full 1300 s) | Patched (790 s, killed early) |
| ---: | ---: | ---: |
| Baseline t=0 | 35.55 MiB | 35.67 MiB |
| Steady-state slope (t=400+) | **+0.150 MiB/s** | **+0.512 MiB/s** |
| Peak | 182.38 MiB | **474.70 MiB** (still climbing when killed) |
| Allocator release event | yes, at t≈390s | **none observed** |
| Connection throughput | ~150/s | ~149/s |
| Connection failures | ~0 | ~0 |

Identical load, no allocator release, 3.4× faster growth, **no
plateau**. The patch was reverted (Cargo.toml + Cargo.lock restored to
HEAD, fork branch deleted).

### What this means for the attribution

The 11 GiB dhat figure attributed to `TcpListenerRunner::create`
**overstated the role of per-flow buffers** in real heap retention.
dhat's `eb` ("exit-live") counter tallies allocations whose `free()`
hadn't been observed when the profiler dropped — under a connection
storm that's dominated by the allocator's free-list bookkeeping, not
by genuinely retained memory. A real leak would manifest as
**resident-page** growth, which the OS-level RSS reading already
shows.

The buffer-size reduction was a hypothesis that fit the dhat output
but not reality:

1. **Smaller per-direction buffers don't shrink real retention** — the
   buffers were never the bottleneck; they were the thing being
   counted by dhat because they're the largest single allocation site
   per accepted connection. The actual leaked state is elsewhere.
2. **The 60 s timeout likely accelerated growth** because each
   prematurely-torn-down smoltcp socket leaves dangling state in
   upstream layers (meow-tunnel's proxy session, rustls connection
   state, the outbound TLS session cache, the NAT/conntrack table)
   that doesn't get notified of the netstack-side eviction. Under
   sustained churn, the upstream state accumulates faster than smoltcp
   can clear its own bookkeeping.
3. **No allocator release event** in the patched run suggests the
   macOS arena classified the new (256 KB per-connection) allocation
   pattern as something to keep in pool. The unpatched run's 124 → 60
   MiB drop at t=390 s was an arena-level coalesce that the patched
   pattern doesn't trigger.

### Revised hypothesis

The genuine RSS growth lives **above netstack-smoltcp** in the
meow-tunnel proxy-session lifecycle:

* rustls TLS sessions held by `meow_transport::tls::TlsLayer` and
  `meow_transport::ws::WsLayer` (dhat rows #5, #10, #13 in the
  exit-live table — small individually but per-connection and slow to
  drop).
* The proxy-side conn-tracking / NAT bookkeeping that meow-tunnel
  keeps for in-flight UDP and TCP sessions — `hashbrown::reserve_rehash`
  (#3) suggests a map that grows monotonically.
* tokio mpsc backlog on the engine-side dispatch channels — `tokio::sync::mpsc::list::Tx::push` (#6) had 268 retained blocks at exit, indicating receivers couldn't keep up.

Next concrete step that has a chance of being right: an iOS-device
Instruments allocations capture, or a `meow-tunnel` cargo-level dhat
run that targets that crate specifically (its allocations are
attributed to `meow-ios-ffi::engine::start` callers from outside
which obscures them in the harness profile).

## Resolution — 2026-05-16 (TCP accept-cap)

The dominant lever wasn't the allocator, wasn't per-flow buffer size,
and wasn't a leak. It was the **concurrent-flow population the
runtime ever holds at once**.

Existing knob: `meow_ios_ffi::tun2socks::TCP_ACCEPT_CAP_DEFAULT`,
exposed at the FFI as `meow_tun_set_accept_cap`. Pre-fix value: 128.
That's the count of in-flight `dispatch_tcp` tasks the runtime will
ever have simultaneously — each holding its full per-flow allocation
(Metadata, `Box<dyn ProxyConn>`, meow's outbound dial buffers, the
netstack-smoltcp stream's tx/rx rings). 128 × per-flow state is what
filled the 122 MiB working set we kept landing on.

### Allocator comparison summary (cap=128, identical 32-conn ×
200 ms-hold stress through github.com:443)

| Allocator | t=0 | t=80s | Plateau | Slope (steady-state) |
| --- | ---: | ---: | --- | ---: |
| Default macOS malloc | 35.55 MiB | ~120 MiB | no, peak 182 MiB | +0.150 MiB/s |
| Default + netstack-smoltcp buffer/timeout trim | 35.67 MiB | ~150 MiB | no, peak 474 MiB | +0.512 MiB/s |
| mimalloc | 43.64 MiB | 580 MiB | yes, ~900 MiB | flat at high baseline |
| jemalloc | 25.34 MiB | 60 MiB | no | ≈+0.18 MiB/s |

### Accept-cap sweep (default allocator, otherwise identical stress)

| Cap | t=0 | Working set | Plateau | Throughput | Failure rate |
| ---: | ---: | ---: | --- | ---: | ---: |
| 128 (pre-fix) | 35.55 MiB | climbing past 182 MiB | no | 147 conn/s | <0.5% |
| **32 (this fix)** | **35.61 MiB** | **38.62 MiB** | **flat from t=10s** | **56 conn/s** | **1.1%** |

The cap=32 working set is **~4× per-flow allocation** (38.62 / 32 ≈
1.2 MiB per flow including netstack-smoltcp's 1.28 MB buffers), which
fits the on-device 50 MB jetsam cap comfortably with substantial
headroom for spikes.

### What ships

* `core/rust/meow-ios-ffi/src/tun2socks.rs`: `TCP_ACCEPT_CAP_DEFAULT`
  changes 128 → 32. Single-line change plus an updated comment that
  cites this doc. `meow_tun_set_accept_cap` remains the runtime knob
  for environments that need to override (slow-DNS, very-high-fanout
  pages); the default just stops being a memory landmine.
* `core/rust/macos-utun-harness/src/main.rs`: new `--tcp-accept-cap`
  CLI flag that wires through `meow_tun_set_accept_cap` for future
  capacity sweeps. The Cargo.toml + main.rs experiments with the
  jemalloc/mimalloc/dhat global allocators are reverted.

### Throughput tradeoff

cap=32 delivers ~38% the conn/s of cap=128 under the stress harness
(56/s vs 147/s). That ratio is from a synthetic pathological workload
(32 concurrent stress generators, 200 ms hold, single hostname). For
the foreground-page-load shape the iOS NE actually serves (one user,
modest fan-out, mostly TLS-reusing flows), the real-world hit is
considerably smaller and is offset by no longer needing to defend
against jetsam-driven extension kills mid-session.

### Follow-ups

* On-device validation with Instruments allocations remains worth
  doing — the macos-harness's macOS allocator behavior is informative
  but not identical to iOS NE's libmalloc + jetsam accounting.
* Consider lifting the runtime knob into a `Settings` toggle for
  "throughput mode" (cap=64 or 96) once on-device numbers are in.
  Slow-DNS environments may want cap=64 in particular.
* Revisit if a future meow-rs release brings per-flow allocations
  down — once the working set per flow shrinks, the cap can grow
  proportionally.

## Reproducing

```bash
# Build harness with dhat-heap instrumentation
cd core/rust/macos-utun-harness
cargo build --release --target aarch64-apple-darwin --features dhat-heap

# Inside the meow-ios-dev Tart VM:
sudo ./meow-utun \
    --config ~/meow-home/effective-config.yaml \
    --home   ~/meow-home \
    --rss-monitor-interval-secs 5 \
    --stress-target github.com:443 \
    --stress-conns 32 \
    --stress-hold-ms 200 \
    --stress-duration-secs 300

# Configure routing in a second shell (see core/rust/macos-utun-harness/README.md).
# After the run, SIGINT the harness *directly* (not the `sudo` parent) to let
# dhat::Profiler drop and write dhat-heap.json.
```

Artifacts from this run:

* `/tmp/meow-stress.log` (host) — uninstrumented 20-minute curve
* `/tmp/dhat-heap.json` (host) — 5-minute dhat profile
* In-VM equivalents under `~/meow-stress.log`, `~/meow-dhat-out/dhat-heap.json`

## Update — 2026-05-18 (accept-cap fix was illusory; leak is per-accepted-flow)

Re-ran the harness against meow-rs v0.7.4 (post-bump from v0.7.3). The
2026-05-16 "cap=32 plateaus at 38.62 MiB" result does **not** reproduce.
Running a sweep across cap, DNS scheme, proxy mode, and connection rate
shows the working-set growth is **per accepted TCP flow, not per
in-flight flow**, and ~4–5 KiB of state is retained per accept for the
process lifetime.

### Sweep (all 32-conn × 200 ms unless noted, github.com:443, 180 s)

| Variant                       | in-flight | total accepts | peak MiB | KiB/accept |
| ----------------------------- | --------: | ------------: | -------: | ---------: |
| Baseline                      |        32 |        45,187 |   200.0 |        3.7 |
| Baseline (180s rerun)         |        32 |        27,031 |   140.3 |        4.0 |
| `--tcp-accept-cap 8`          |   ≤8 cap  |        27,000 |   141.0 |        4.0 |
| Do53 nameservers              |        32 |        26,933 |   140.3 |        4.0 |
| `mode: direct`                |        32 |        19,137 |   110.3 |        4.0 |
| `--stress-conns 4`            |         4 |         3,411 |    50.4 |        4.9 |
| `--stress-conns 8 --hold 1000`|         8 |         1,424 |    40.7 |        4.7 |

### What the sweep tells us

* **Accept cap is not a memory lever.** cap=8 and cap=32 produce identical
  curves under realistic stress because the stress workers cycle faster
  than the cap can bind. The 2026-05-16 "cap=32 plateaus at 38.62 MiB"
  number was an artifact of the workers being throttled at 56 conn/s by
  *something other than the cap* (likely a DNS-bound bottleneck on the
  prior v0.7.3 build), not the cap actually limiting peak working set.
* **DNS scheme is not a lever.** Switching from DoH to Do53 nameservers
  produced bit-identical RSS curves, so the new v0.7.4 in-tree DNS
  client (which lacks the connection pooling hickory-resolver had) is
  **not** the dominant retention site under this stress shape.
* **Proxy outbound is not a lever.** `mode: direct` (which skips the
  proxy dial / rustls handshake entirely) leaks ~4.0 KiB per accept,
  same as `mode: rule`. The retention happens before, in, or around
  `meow_tunnel::tcp::handle_tcp`'s scaffolding common to every mode.
* **In-flight count is not the lever, accept count is.** The
  `conns=8/hold=1000` row generates 1/19th the accepts as the baseline
  and produces 1/3 the heap growth — proportional to accept count.
  All RSS arithmetic lands at ~4–5 KiB/accept regardless of how those
  accepts are spread over time.

### Where the 4 KiB lives — narrowed but not pinpointed

The investigation has eliminated:
1. Per-flow buffer size — proven false 2026-05-16.
2. Meow-tunnel `Statistics.connections` map — RAII `ConnectionGuard`
   removes the entry on every exit path (verified by reading
   `crates/meow-tunnel/src/tcp.rs`).
3. DoH per-query TLS handshake state (the v0.7.4 in-tree DNS client
   uses `Connection: close`, no pooling) — Do53 run had identical
   growth.
4. Proxy outbound rustls / WS / TLS session state — direct mode had
   identical growth.
5. FFI flow registry — `tcp_flows().remove(&flow_id)` runs on every
   task exit (verified by reading `core/rust/meow-ios-ffi/src/tun2socks.rs:467-481`).

What remains suspected (in descending priority):
1. **netstack-smoltcp's per-socket retention through CLOSED / TIME_WAIT**
   — the ~30% post-stress RSS drop (200 → 144 MiB) over ~600 s of idle
   has the right shape for TIME_WAIT release. Need to read
   `netstack_smoltcp::tcp::TcpListenerRunner` for what it keeps after
   the user-facing stream is dropped.
2. **An unbounded hashbrown table in meow-rs or meow-tunnel that
   inserts per-flow and never evicts** — fits the durable ~70% (~2.4
   KiB/accept) that does *not* reclaim post-stress. The 2026-05-16
   dhat #2 row (70 MiB pre-sized hashbrown baseline, 4 tables) is the
   natural place to start grepping.
3. **Tokio task header retention** — every accept spawns one
   `dispatch_tcp` task; if the runtime's task slot ring is allocating
   without reclaiming, that fits "per-accept, durable." Tokio's
   `tokio::runtime::scheduler::multi_thread::worker::Shared` does keep
   a per-worker task injector queue; worth profiling.

### Implication for the iOS ship

The 40 MB self-restart threshold landed today (`PacketTunnelProvider.m`
phys_footprint watchdog, PR #154) gives ~16 MB of headroom above the
~24 MB cold-start baseline. At 4.5 KiB durable + ~1.5 KiB transient per
flow, the extension self-restarts after roughly **3,000–3,500 cumulative
TCP accepts**. For a typical foreground browsing session that's enough
for tens of minutes; for a heavy multi-tab / many-CDN workload it's
considerably less. The shipping cure is upstream — find the durable
~2.4 KiB/accept and stop allocating it. Restart-on-pressure is the
*safety net*, not the fix.

### Suggested next steps

1. **Read `netstack_smoltcp::tcp::TcpListenerRunner` source** for what
   it retains after a stream is dropped — specifically whether the
   accepted-connections map, the per-listener egress channel, or
   smoltcp's `SocketSet` retains anything that doesn't get released on
   smoltcp's CLOSED transition.
2. **dhat-instrument a 90-second slow-hold run** (`conns=8 hold=1000`)
   under realistic stress shape — the v0.7.3 dhat run was a connection
   storm that suffocated the profiler. A slower, accept-bound shape
   should let dhat capture meaningful "retained at sweep" rankings
   that reflect the durable leak rather than allocator bookkeeping.
3. **Move `Statistics.connections` to a connection-count tag rather
   than a `DashMap<String, ConnectionInfo>`** — the entry is bounded
   by RAII discipline today, but a smaller value type (or just a
   counter) eliminates a ~400-byte per-flow allocation that has no
   user-visible value once the connection is closed.

### Reproducing this sweep

The harness now self-shutdowns when `--stress-duration-secs` expires
(commit on `chore/meow-rs-0.7.4` branch, since merged into v0.7.4
bump PR #154). The Tart VM `meow-ios-dev` was used throughout; the
helper script `/tmp/run-stress.sh` in the VM takes `CAP`, `CONNS`,
`HOLD_MS`, `DURATION`, `CONFIG` as env vars.

```bash
# All runs are 180 s, default config unless `CONFIG=…` is set.
DURATION=180 CAP=32 CONNS=32 HOLD_MS=200 /tmp/run-stress.sh   # baseline
DURATION=180 CAP=8  CONNS=32 HOLD_MS=200 /tmp/run-stress.sh   # cap sweep
DURATION=180 CAP=32 CONNS=4  HOLD_MS=200 /tmp/run-stress.sh   # low-conn
DURATION=180 CAP=32 CONNS=8  HOLD_MS=1000 /tmp/run-stress.sh  # slow-hold
DURATION=180 CAP=32 CONNS=32 CONFIG=~/meow-home/effective-config.do53.yaml \
    /tmp/run-stress.sh                                          # Do53
DURATION=180 CAP=32 CONNS=32 CONFIG=~/meow-home/effective-config.direct.yaml \
    /tmp/run-stress.sh                                          # direct mode
```
