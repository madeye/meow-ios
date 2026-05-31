# Investigation — UDP NAT session / reply-reader memory leak

## Status

- **Branch:** `fix/meow-tunnel-memleak-b5406d3`
- **Fix:** APPLIED to `core/rust/meow-ios-ffi/src/tun2socks.rs`
- **Gates:** `cargo fmt`, `cargo clippy -p meow-ios-ffi`, `cargo test -p
  meow-ios-ffi --lib` all green (details verbatim below).

## The leak

UDP NAT sessions and their per-flow reply-reader tasks had **no count cap**.
Eviction was idle-TTL only (10 s first-reply deadline, 60 s post-first-reply
idle backstop, plus the 15 s background NAT sweeper added in PR #207). Idle-TTL
never fires for a flow that exchanges >=1 datagram per idle window — QUIC,
WebRTC, online games, DNS fan-out, or a source-port-fanning buggy/hostile app.
Each such "immortal" flow permanently pins:

- one `nat_table` entry (`Arc<UdpSession>`),
- one `reply_readers` HashSet entry,
- one spawned reply-reader task holding its own `Arc<UdpSession>` + a 4 KiB
  read buffer.

N concurrent active flows => N of each, growing monotonically toward the
~50 MB PacketTunnel jetsam cap. This is the exact known-open follow-up recorded
in MEMORY.md (`project_udp_nat_sweeper_leak.md`: "UDP has no session cap").

## Root cause

The `udp_sem` Semaphore (`UDP_BURST_CAP = 512`) *looked* like a cap but was
not. In `dispatch_udp`, the `OwnedSemaphorePermit` was **dropped (`drop(permit)`)
before** the NAT insert / `handle_udp` / `reply_readers` insert / reader spawn.
The permit therefore bounded only the brief resolve/connect *dispatch window*,
not the live-session population. This is the classic "permit released before the
long-lived resource is created" bug — the live session count was completely
unbounded.

## The fix (bound added)

Convert `udp_sem` into a **true live-session cap** by holding the permit for the
whole flow lifetime instead of dropping it early. Minimal and state-bounding
(the only valid RSS lever per the jemalloc-on-Darwin note — no allocator
tweaks).

Single file changed: `core/rust/meow-ios-ffi/src/tun2socks.rs` (+64/-19).

1. **`UDP_BURST_CAP` doc comment (~L210-222)** — rewrote the comment to document
   that 512 is now a live-UDP-session cap (NAT entry + reply_readers entry +
   `Arc<UdpSession>` + 4 KiB buffer per permit), sized inside the ~50 MB NE
   budget; on cap-hit new flows are dropped (UDP is lossy / retries) rather
   than evicting working flows.

2. **`dispatch_udp` (~L1098-1149)** — **removed `drop(permit)`** that preceded
   `pre_resolve`. Replaced the old "release before resolve" rationale with a
   comment explaining the permit is now MOVED into the reply-reader task and
   released only when that task exits and clears its NAT + reply_readers state,
   so the permit population tracks the live-session population exactly. On every
   early-return path (resolve failure, `handle_udp` bail, dedup hit) `permit`
   drops at end of scope — correct, since those paths create no live session.
   Threaded `permit` through to `spawn_udp_reply_reader(..., permit)`.

3. **`spawn_udp_reply_reader` (~L1131-1153)** — added a
   `permit: OwnedSemaphorePermit` parameter and
   `#[allow(clippy::too_many_arguments)]` (the fn now takes 8 args). Inside the
   spawned task, bound the permit as `let _permit = permit;` so it is held for
   the entire reader lifetime and released alongside the
   `nat_table.remove(&key)` / `reply_readers.lock().remove(&key)` cleanup at
   task exit.

4. **UDP accept-loop warn message (~L607)** — "UDP burst cap reached" -> "UDP
   live-session cap reached" to match the new semantics.

### Why this bounds the leak

The accept loop uses `try_acquire_owned()`: when all 512 permits are held by
live reader tasks, new datagrams are dropped (`continue`) instead of spawning a
513th flow. Because a permit is now released only when its reader task tears
down (and clears both the NAT and reply_readers entries on the same path), the
NAT table, reply_readers set, reader-task count, and pinned 4 KiB buffers are
all hard-bounded at 512 regardless of how many flows stay "active" forever. RSS
contribution from this path is bounded at 512 * (UdpSession + 4 KiB), well
inside the ~50 MB jetsam cap. The existing idle-TTL/sweeper logic is unchanged
and still reaps quiet flows early, freeing permits sooner.

### rss counters

`DebugCounts` (consumed by the harness `rss_monitor`) already tracks
`nat_table` and `reply_readers` sizes; both are now bounded by the same cap, so
no counter wiring change was needed.

### What was deliberately NOT changed

- No allocator changes (jemalloc/madvise do nothing for RSS on Darwin).
- The reply_readers dedup gate already clears its entry on the same teardown
  path as the NAT entry, so cap/teardown can't desync the two.
- The sweeper remains inside `get_runtime().enter()` (PR #207).
- LRU-with-MAX_SESSIONS eviction was considered (verdict's "additionally /
  alternatively") but is heavier; the permit-lifetime cap is the smallest
  correct fix that fully bounds the structure, so it was chosen alone.

## Verification results (verbatim)

`cargo fmt --all -- --check`:

```
FMT_EXIT:0
```

`cargo clippy -p meow-ios-ffi --all-targets -- -D warnings`:

```
    Checking meow-ios-ffi v0.1.0 (/Volumes/DATA/workspace/meow-ios/core/rust/meow-ios-ffi)
    Finished `dev` profile in 5.04s
    CLIPPY_FFI_EXIT:0
```

`cargo test -p meow-ios-ffi --lib`:

```
running 27 tests
...
test result: ok. 27 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
TEST_LIB_EXIT:0
```

### Pre-existing, unrelated clippy failure (NOT from this change)

A full-workspace `cargo clippy --all-targets -- -D warnings` fails in the
sibling dev-only crate `macos-utun-harness` (`src/main.rs`):

- L5 `use std::time::Duration;` — redundant import.
- L55 `unused import: tun2socks`.

`git diff --stat main` shows the ONLY file this change touches is
`core/rust/meow-ios-ffi/src/tun2socks.rs`; `git show main:.../main.rs` confirms
both offending lines are present verbatim on clean `main`. They are pre-existing
warnings-as-errors in untouched code, not caused by this fix. The shipping
crate (`meow-ios-ffi`) is clippy-clean under `-D warnings`.
