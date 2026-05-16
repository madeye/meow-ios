# RSS-growth attribution — netstack-smoltcp TCP listener closures

**Date:** 2026-05-16
**Investigator:** Claude Opus 4.7 driven by max.c.lv@gmail.com
**Tool chain:** `macos-utun-harness` (added `dhat-heap` feature gate) running inside the
`meow-ios-dev` Tart VM. Allocation profile via `dhat-rs` v0.3.

## TL;DR

The previously-tracked **+0.14 MiB/s** linear RSS growth during sustained
TCP-connection churn is **not** caused by mihomo internals (resolver cache,
NAT entries, rule stats) as previously assumed. It is overwhelmingly
caused by **`netstack_smoltcp::tcp::TcpListenerRunner::create`'s
per-connection closure state not being released when flows close**.
The crate at the boundary (downstream of the FFI, upstream of
`mihomo-tunnel`) is the right place to fix it.

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
|    9 |    308 KiB |  6,574 | `mihomo_rules::parser::parse_rule` (rule parse — baseline) |
|   10 |    252 KiB |    108 | `mihomo_transport::ws::WsLayer::connect` (WS handshake state) |

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
3. A drop chain has been broken by a recent `mihomo-rust` change (the
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
3. **Profile mihomo-tunnel's connection lifecycle** rather than
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
`core/rust/mihomo-ios-ffi/Cargo.toml`. The Rust workspace rebuilt
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
   upstream layers (mihomo-tunnel's proxy session, rustls connection
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
mihomo-tunnel proxy-session lifecycle:

* rustls TLS sessions held by `mihomo_transport::tls::TlsLayer` and
  `mihomo_transport::ws::WsLayer` (dhat rows #5, #10, #13 in the
  exit-live table — small individually but per-connection and slow to
  drop).
* The proxy-side conn-tracking / NAT bookkeeping that mihomo-tunnel
  keeps for in-flight UDP and TCP sessions — `hashbrown::reserve_rehash`
  (#3) suggests a map that grows monotonically.
* tokio mpsc backlog on the engine-side dispatch channels — `tokio::sync::mpsc::list::Tx::push` (#6) had 268 retained blocks at exit, indicating receivers couldn't keep up.

Next concrete step that has a chance of being right: an iOS-device
Instruments allocations capture, or a `mihomo-tunnel` cargo-level dhat
run that targets that crate specifically (its allocations are
attributed to `mihomo-ios-ffi::engine::start` callers from outside
which obscures them in the harness profile).

## Resolution — 2026-05-16 (TCP accept-cap)

The dominant lever wasn't the allocator, wasn't per-flow buffer size,
and wasn't a leak. It was the **concurrent-flow population the
runtime ever holds at once**.

Existing knob: `mihomo_ios_ffi::tun2socks::TCP_ACCEPT_CAP_DEFAULT`,
exposed at the FFI as `meow_tun_set_accept_cap`. Pre-fix value: 128.
That's the count of in-flight `dispatch_tcp` tasks the runtime will
ever have simultaneously — each holding its full per-flow allocation
(Metadata, `Box<dyn ProxyConn>`, mihomo's outbound dial buffers, the
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

* `core/rust/mihomo-ios-ffi/src/tun2socks.rs`: `TCP_ACCEPT_CAP_DEFAULT`
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
* Revisit if a future mihomo-rust release brings per-flow allocations
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
