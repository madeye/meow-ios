//! tun2socks using netstack-smoltcp: Swift pushes raw IP packets in via
//! [`ingest`], netstack terminates TCP and UDP sessions in a userspace
//! smoltcp stack, and each flow dispatches directly into
//! `meow_tunnel::{tcp,udp}::handle_*` — no SOCKS5 loopback, no cross-process
//! hop.
//!
//! Egress packets (netstack output) are handed back to Swift via a C
//! callback registered in [`start`]. No file descriptors cross the FFI.
//!
//! DNS: A (1) queries are delegated to meow's resolver running in fake-IP
//! mode (`DnsServer::handle_query`). AAAA (28) queries are answered
//! NOERROR-empty by the intercept itself, unconditionally — only the IPv4
//! fake-IP path is proxied, so stripping AAAA forces every client onto it
//! instead of leaking (or black-holing) connections over v6. Anything else
//! (HTTPS=65, SVCB=64, TXT=16, MX=15, PTR=12, …) is forwarded as a raw UDP
//! packet to the pinned upstream pool and the response is injected straight
//! back. meow's DnsServer returns NXDOMAIN for non-A/AAAA queries, which
//! kills modern iOS connection setup (Safari's HTTPS-record probe, ECH,
//! DNS-SD, mDNS-fallback) — the passthrough path lets those queries get a
//! real answer instead.
//!
//! NEDNSSettings advertises a TUN-subnet address as the system resolver, so
//! every UDP DNS query arrives as an in-TUN IP packet; the ingress loop below
//! intercepts it pre-stack, branches on qtype, and injects the reply back
//! into the egress channel with src/dst + ports swapped. No UDP listener
//! socket exists — there's nothing for one to listen on. The resolver itself
//! owns fake-IP synthesis, reverse mapping, AAAA / hosts / NXDOMAIN
//! semantics, and TTL handling for A/AAAA; the FFI owns only the qtype
//! peek + the upstream forward.
//!
//! TCP/UDP destination IPs come back as fake-IPs from meow's resolver pool.
//! `dispatch_tcp` and `dispatch_udp` pass the literal `dst.ip()` to
//! `meow_tunnel`, whose `pre_handle_metadata` reverses any fake-IP back to
//! the original qname before rule matching — so the rule / proxy chain still
//! sees the hostname rather than the synthetic IP, without the FFI keeping
//! its own pool.

use crate::logging;
use futures::{SinkExt, StreamExt};
use meow_common::{ConnType, Metadata, Network, ProxyConn};
use meow_dns::DnsServer;
use meow_tunnel::tunnel::TunnelInner;
use meow_tunnel::udp::UdpSession;
use parking_lot::Mutex;
use std::collections::HashSet;
use std::io;
use std::net::SocketAddr;
use std::os::raw::c_void;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{mpsc, Notify, OwnedSemaphorePermit, Semaphore};
use tokio_util::task::TaskTracker;
use tracing::{info, trace, warn};

type UdpMsg = (Vec<u8>, SocketAddr, SocketAddr);
type AnyIpPktFrame = Vec<u8>;
type NetstackTcpStream = lwip::TcpStream;

/// Matches the cbindgen-emitted typedef in `meow_core.h`: Rust calls this
/// whenever netstack or DNS produces an egress packet bound for the utun.
pub type WritePacketFn = unsafe extern "C" fn(ctx: *mut c_void, data: *const u8, len: usize);

/// Wraps the raw context pointer so it's `Send` across the tokio runtime. The
/// contract is that Swift keeps the referent alive between `meow_tun_start`
/// and `meow_tun_stop` (typically via `Unmanaged.passRetained`); we treat the
/// pointer as opaque.
#[derive(Copy, Clone)]
struct EmitCtx(*mut c_void);
unsafe impl Send for EmitCtx {}
unsafe impl Sync for EmitCtx {}

struct EgressEmitter {
    ctx: EmitCtx,
    cb: WritePacketFn,
}

impl EgressEmitter {
    fn emit(&self, packet: &[u8]) {
        unsafe { (self.cb)(self.ctx.0, packet.as_ptr(), packet.len()) };
    }
}

static TUN2SOCKS_RUNNING: AtomicBool = AtomicBool::new(false);
// Monotonic instance id. `start()` bumps it; the spawned run task captures
// its own value and only performs end-of-life cleanup (clearing
// `ingress_slot`, lowering `TUN2SOCKS_RUNNING`) if it is STILL the current
// generation. Without the guard, a rapid stop()→start() (sleep/wake +
// path-change churn both restart tun2socks back-to-back) let the OLD task's
// deferred cleanup steal the NEW instance's ingress sender and flag:
// `stop()` is fire-and-forget, so the old task was still parked in `recv()`
// when the new one started, and its teardown ran arbitrarily later.
static TUN2SOCKS_GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub(crate) static ACTIVE_TCP_CONNS: std::sync::atomic::AtomicI64 =
    std::sync::atomic::AtomicI64::new(0);

/// JoinHandle of the current (or most recent) run task. The next `start()`
/// takes it and awaits its teardown (bounded) before building a new lwip
/// netstack — the lwip globals (`OUTPUT_CB_PTR`, netif hooks, pcb lists)
/// assume a single live stack, so two overlapping `run_tun2socks` instances
/// are never allowed.
fn run_handle_slot() -> &'static Mutex<Option<tokio::task::JoinHandle<()>>> {
    static SLOT: OnceLock<Mutex<Option<tokio::task::JoinHandle<()>>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

// TCP accept-side burst cap. Without this, every smoltcp-accepted flow
// spawns a `dispatch_tcp` task immediately — and under a real burst (e.g.
// loading a content-rich CN homepage that fans out to 50+ subdomains in
// the first second), 1000+ concurrent dispatch tasks each hold their own
// per-flow state (Metadata, Box<dyn ProxyConn>, meow's outbound dial
// buffers, the netstack stream's tx/rx ring). The 10-min VM stress run
// peaked at 440 MiB of RSS in the first ~10 s of load — 8.8× the on-device
// 50 MB jetsam cap — almost entirely from the size of this in-flight set.
//
// Tunable at runtime via [`set_accept_cap`] / `meow_tun_set_accept_cap`.
// The atomic is sampled at `start()` to size the per-tunnel semaphore;
// changes after start take effect on the next `meow_tun_start`. We don't
// reseat a live semaphore — tokio's Semaphore can `add_permits` but not
// shrink without forgetting permits mid-flight, which would let live flows
// outrun the new cap until they drain. Restart-scoped is cleaner.
//
// 32 default. Empirical: a 10-min Tart-VM stress at 32-concurrent ×
// 200 ms-hold connections through github.com:443 — exhaustively
// instrumented in docs/INVESTIGATION-2026-05-16-stress-rss-netstack-
// smoltcp.md — produced:
//   cap=128: 122 MiB working set, +0.150 MiB/s slope, peak 182 MiB
//   cap= 32:  38 MiB working set, **flat from t=10 s**, no slope
// The cap, not the underlying allocator or per-flow buffer size, was
// the dominant lever. The accept-side semaphore caps the in-flight
// dispatch task population, which directly bounds the per-flow state
// (Metadata + Box<dyn ProxyConn> + outbound dial buffers + the
// netstack stream's tx/rx ring) the runtime ever holds at once. At
// cap=32 the working set is ~4 × per-flow, comfortably below iOS NE's
// 50 MB jetsam cap with substantial headroom for spikes.
//
// Throughput tradeoff: ~25% of the cap=128 conn/s rate (56/s vs
// 147/s in the same stress harness). Acceptable for the foreground
// page-load shape we actually need to serve; iOS NE's whole reason
// for existing is to fit in 50 MB, not to win a benchmark.
const TCP_ACCEPT_CAP_DEFAULT: usize = 256;
static TCP_ACCEPT_CAP: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(TCP_ACCEPT_CAP_DEFAULT);

/// Set the TCP accept cap. Takes effect on the next `meow_tun_start`.
/// `cap` must be > 0 — zero would deadlock the accept loop. Returns true
/// if applied, false on invalid input.
pub fn set_accept_cap(cap: usize) -> bool {
    if cap == 0 {
        return false;
    }
    TCP_ACCEPT_CAP.store(cap, Ordering::Relaxed);
    true
}

/// Read the currently-configured accept cap. Reflects the value the next
/// `meow_tun_start` will use, not the size of any live semaphore.
pub fn accept_cap() -> usize {
    TCP_ACCEPT_CAP.load(Ordering::Relaxed)
}

// Per-flow dial deadline. Bounds the time `dispatch_tcp` waits for the
// relay's first byte of progress on the netstack stream before declaring
// the dial hung and dropping the future. See
// docs/INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md for the
// failure mode: `DirectAdapter::dial_tcp` awaits `TcpStream::connect`
// with no timeout, and an iOS reachability-cache / scoped-routing
// transient can leave the connect hanging until cap-pressure eviction
// reaps the flow. With the deadline, the app sees a RST in
// `DIAL_DEADLINE_MS` ms instead of 30 s, the `tcp_accept_sem` permit is
// released promptly, and `ConnectionGuard`'s Drop runs the meow
// session cleanup on the discarded future.
//
// 10 s default: safely above cold cellular handshakes against distant
// CN PoPs (~5-8 s observed) and below Mobile Safari's ~12 s
// request-timeout floor, so the app's own retry loop kicks in.
// Tunable at runtime via [`set_dial_deadline_ms`] /
// `meow_tun_set_dial_deadline_ms` — set to 0 to disable the watchdog.
const DIAL_DEADLINE_MS_DEFAULT: u64 = 10_000;
static DIAL_DEADLINE_MS: AtomicU64 = AtomicU64::new(DIAL_DEADLINE_MS_DEFAULT);

/// Set the per-flow dial deadline, in milliseconds. `0` disables the
/// deadline (no watchdog — flows that hang in `dial_tcp` will only be
/// reaped when the accept cap forces a longest-idle eviction). Returns
/// true unconditionally.
pub fn set_dial_deadline_ms(ms: u64) -> bool {
    DIAL_DEADLINE_MS.store(ms, Ordering::Relaxed);
    true
}

/// Read the currently-configured dial deadline, in milliseconds. `0`
/// means the watchdog is disabled.
pub fn dial_deadline_ms() -> u64 {
    DIAL_DEADLINE_MS.load(Ordering::Relaxed)
}

// Per-UDP-session first-reply deadline. The symmetric counterpart to
// DIAL_DEADLINE_MS for the UDP path. UDP doesn't connect, so there's no
// `TcpStream::connect` hang to bound — but iOS auto-bypass can silently
// drop the outbound sendto when the kernel's scoped-routing cache is
// stale, in which case the upstream never sees the datagram and the
// reply reader sits forever on `session.conn.read_packet`. With this
// deadline, a session that produces zero replies within the budget is
// evicted from `nat_table` + `reply_readers`, so the next app datagram
// dispatches a fresh socket against (hopefully) a refreshed iOS route.
//
// 10 s default to match TCP's `DIAL_DEADLINE_MS`. The cost for legit
// no-reply UDP traffic (fire-and-forget telemetry, mDNS) is a
// dispatch + bind churn every 10 s — negligible relative to even a
// single round-trip's allocation cost. Tunable at runtime via
// [`set_udp_first_reply_deadline_ms`] / `meow_tun_set_udp_first_reply_deadline_ms`;
// set to 0 to opt out.
const UDP_FIRST_REPLY_DEADLINE_MS_DEFAULT: u64 = 10_000;
static UDP_FIRST_REPLY_DEADLINE_MS: AtomicU64 = AtomicU64::new(UDP_FIRST_REPLY_DEADLINE_MS_DEFAULT);

/// Set the per-UDP-session first-reply deadline, in milliseconds. `0`
/// disables the deadline (legacy unbounded behaviour). Returns true
/// unconditionally.
pub fn set_udp_first_reply_deadline_ms(ms: u64) -> bool {
    UDP_FIRST_REPLY_DEADLINE_MS.store(ms, Ordering::Relaxed);
    true
}

/// Read the currently-configured UDP first-reply deadline, in
/// milliseconds. `0` means the watchdog is disabled.
pub fn udp_first_reply_deadline_ms() -> u64 {
    UDP_FIRST_REPLY_DEADLINE_MS.load(Ordering::Relaxed)
}

// Per-TCP-flow idle TTL. Closes the wedge the dial deadline can't reach:
// a relay whose dial succeeded but whose flow then goes quiet forever.
// The canonical shape (2026-06-06 after-hours-idle incident, flow stuck
// `in_progress` 16 h in the device log): the upstream proxy times out an
// idle connection and EOFs, `copy_bidirectional_buf` half-closes our side
// and waits for the app's FIN — but the app is suspended and never FINs.
// The relay task parks forever, pinning a `tcp_accept_sem` permit and an
// lwip pcb. Accumulate ~256 of those over hours of idle and every new
// connection is dropped at the accept cap: "VPN connected, no traffic."
//
// The sweeper ticks every TCP_IDLE_SWEEP_INTERVAL and aborts flows whose
// `last_active_ms` is older than the TTL. Aborting drops the relay future
// (RAII cleanup on both halves, permit released) and the netstack stream
// (RST / tcp_close to the app side, which reconnects on next use).
//
// 600 s default. Raised from 300 s after the 2026-06-14 long-lived-TCP audit:
// 300 s (v2ray `connIdle` / sing-box inactivity defaults) reaps a no-keepalive
// server-push channel (live feed, SSE, some game lobbies) whenever its quiet
// gap between pushes exceeds 5 min, even though the flow is alive. `touch()`
// refreshes on BOTH directions, so any flow with traffic — including a
// well-behaved WebSocket sending ping/pong — never hits this; only a flow
// genuinely silent in both directions is reaped. 10 min covers the common
// push-interval range while still reclaiming a wedged-but-silent pcb (the
// after-hours-idle failure mode above) well inside the time it would take to
// accumulate ~256 of them against the accept cap. Tunable at runtime via
// [`set_tcp_idle_ttl_ms`] / `meow_tun_set_tcp_idle_ttl_ms`; 0 disables.
const TCP_IDLE_TTL_MS_DEFAULT: u64 = 600_000;
static TCP_IDLE_TTL_MS: AtomicU64 = AtomicU64::new(TCP_IDLE_TTL_MS_DEFAULT);

const TCP_IDLE_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(30);

// After the app half-closes (local FIN), how long the relay may stay quiet in
// the DOWNLOAD direction before `dispatch_tcp` drops it. The window is
// *idle-based*, not absolute: each downstream byte refreshes it (see the
// local-FIN arm in `dispatch_tcp`), so a slow/large half-closed response — a
// raw TCP half-close that keeps receiving, an HTTP/1.1 request-body EOF before
// a big response — drains fully instead of being truncated by a fixed timer.
// Only a half-closed flow that also goes download-silent is dropped, and the
// 300/600 s idle sweeper is the ultimate backstop regardless.
const HALF_CLOSE_IDLE_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

/// Set the per-TCP-flow idle TTL, in milliseconds. `0` disables the
/// sweeper (legacy behaviour: wedged flows hold their accept permit until
/// tunnel restart). Returns true unconditionally.
pub fn set_tcp_idle_ttl_ms(ms: u64) -> bool {
    TCP_IDLE_TTL_MS.store(ms, Ordering::Relaxed);
    true
}

/// Read the currently-configured TCP idle TTL, in milliseconds. `0` means
/// the sweeper is disabled.
pub fn tcp_idle_ttl_ms() -> u64 {
    TCP_IDLE_TTL_MS.load(Ordering::Relaxed)
}

// Live-UDP-session cap. This is NOT merely a burst/dispatch-window cap: the
// `udp_sem` permit acquired per datagram in the accept loop is moved into the
// per-flow reply-reader task (see `spawn_udp_reply_reader`) and held until that
// task exits, so the permit population equals the live-flow population. It
// therefore bounds the count of simultaneously-live UDP flows — each pinning a
// NAT entry, a `reply_readers` entry, an `Arc<UdpSession>` and a 4 KiB reader
// buffer — which the idle-TTL sweeper alone cannot do (the sweeper only reaps
// flows quiet > 60 s, never active ones). 512 live flows * (UdpSession + 4 KiB)
// is comfortably inside the ~50 MB NE jetsam budget; once full, new flows are
// dropped (the app's UDP is lossy and retries) rather than evicting working
// ones.
const UDP_BURST_CAP: usize = 512;

// In-TUN UDP/53 handler fan-out cap. Each UDP/53 packet spawns an async
// task that may block on a real DNS round-trip (forward_dns_to_upstream
// for non-A/AAAA, meow's resolver for A/AAAA). Without a cap, a DNS
// storm (Safari HTTPS/SVCB probes, mDNS-style fan-out, malicious flood)
// produces unbounded `tokio::spawn` calls each holding the inbound IP
// frame plus its upstream socket. 256 is sized to match the UDP burst
// cap above — DNS is conceptually a slice of UDP, not a separate budget.
const DNS_BURST_CAP: usize = 256;
static DNS_CAP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

// Per-DNS-task wall-clock cap. Belt-and-suspenders for DNS_BURST_CAP: the
// cap bounds concurrent tasks but only a timeout bounds individual task
// lifetime, and 256 stuck tasks against a hung upstream would otherwise
// permanently exhaust the cap. 5s covers the worst legitimate iOS
// resolver round-trip (cold DNS-over-HTTPS in a captive-portal scenario)
// while bounding the lockout window.
const DNS_TASK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

// Throttle slot for the silent-egress-drop log. The egress path drops
// outbound frames non-blockingly when egress_rx is saturated (Swift-side
// writePackets is slow); without a log the user sees a throughput cliff
// with no on-device signal. Throttled via warn_capped to once per second.
static EGRESS_DROP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

// Throttle slot for the silent stack-ingress-drop log. The main ingress loop
// drops inbound frames non-blockingly when the stack-driver queue is saturated
// (see the drop site in `run_tun2socks`); without a log the user sees a
// throughput cliff with no on-device signal. Throttled via warn_capped.
static STACK_INGRESS_DROP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

static UDP_CAP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

// Throttle slot for the UDP reply-writer-backpressure drop log. When the
// shared `udp_reply_tx` channel is momentarily full the reply reader drops the
// datagram (UDP is lossy) and keeps the session alive; without a log this
// silent loss has no on-device signal. Throttled via warn_capped.
static UDP_REPLY_DROP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

static TCP_FLOW_ID_SEQ: AtomicU64 = AtomicU64::new(1);

/// Per-active-flow timestamp. The Arc-shared cell lets `IdleTrackingConn`
/// bump `last_active_ms` on every successful poll without taking the
/// global flow-table lock; the sweep reader walks the table to compare.
struct FlowState {
    last_active_ms: AtomicU64,
}

/// Registry entry for one in-flight TCP flow. Aborting `abort` drops the
/// `dispatch_tcp` future, which closes both halves of the relay — the
/// netstack stream side and the in-process meow dispatch (whichever
/// outbound the rule engine selected: proxy, direct, or reject).
struct FlowRecord {
    state: Arc<FlowState>,
    abort: tokio::task::AbortHandle,
    src: SocketAddr,
    dst: SocketAddr,
}

fn tcp_flows() -> &'static dashmap::DashMap<u64, FlowRecord> {
    static M: OnceLock<dashmap::DashMap<u64, FlowRecord>> = OnceLock::new();
    M.get_or_init(dashmap::DashMap::new)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Find the flow with the oldest `last_active_ms`, remove it from the
/// registry, and abort its task. Called from the accept loop when the
/// accept semaphore is saturated — eviction is cap-triggered, not
/// time-triggered, and always targets the longest-idle flow first.
/// Returns the evicted flow's id, or `None` if the registry is empty.
#[cfg_attr(not(test), allow(dead_code))]
fn evict_oldest_idle_tcp_flow() -> Option<u64> {
    let flows = tcp_flows();
    let mut oldest: Option<(u64, u64)> = None;
    for entry in flows.iter() {
        let ts = entry.value().state.last_active_ms.load(Ordering::Relaxed);
        match oldest {
            None => oldest = Some((*entry.key(), ts)),
            Some((_, best_ts)) if ts < best_ts => oldest = Some((*entry.key(), ts)),
            _ => {}
        }
    }
    let (id, _) = oldest?;
    let (_, rec) = flows.remove(&id)?;
    rec.abort.abort();
    warn!(
        "tun2socks: TCP cap reached, evicting longest-idle flow {} {} -> {}",
        id, rec.src, rec.dst
    );
    Some(id)
}

/// One sweep pass: remove + abort every flow whose `last_active_ms` is at
/// least `ttl_ms` older than `now`. Remove-then-abort order matters — an
/// aborted task never reaches its own `tcp_flows().remove(..)` cleanup, so
/// the sweeper owns the registry removal. Returns the number of flows
/// reaped. Factored out of [`run_tcp_idle_sweeper`] so unit tests can
/// drive it with a synthetic clock.
fn sweep_idle_tcp_flows(ttl_ms: u64, now: u64) -> usize {
    let flows = tcp_flows();
    let expired: Vec<u64> = flows
        .iter()
        .filter(|e| {
            now.saturating_sub(e.value().state.last_active_ms.load(Ordering::Relaxed)) >= ttl_ms
        })
        .map(|e| *e.key())
        .collect();
    let mut reaped = 0usize;
    for id in expired {
        if let Some((_, rec)) = flows.remove(&id) {
            rec.abort.abort();
            warn!(
                "tun2socks: idle TTL ({} ms) exceeded, closing flow {} {} -> {}",
                ttl_ms, id, rec.src, rec.dst
            );
            reaped += 1;
        }
    }
    reaped
}

/// Periodic idle-flow sweeper (see `TCP_IDLE_TTL_MS` docs above for the
/// failure mode it exists to prevent). Re-reads the TTL atomic every tick
/// so runtime tuning applies without a tunnel restart.
async fn run_tcp_idle_sweeper() {
    loop {
        tokio::time::sleep(TCP_IDLE_SWEEP_INTERVAL).await;
        let ttl_ms = TCP_IDLE_TTL_MS.load(Ordering::Relaxed);
        if ttl_ms == 0 {
            continue;
        }
        sweep_idle_tcp_flows(ttl_ms, now_ms());
    }
}

/// Abort every flow in the registry. Dropping the `dispatch_tcp` future
/// closes both halves of the relay. Returns the number of flows closed.
/// Exposed via FFI (`meow_tun_close_all_tcp_flows`) for emergency teardown.
pub fn close_all_tcp_flows() -> usize {
    let flows = tcp_flows();
    let mut count = 0usize;
    flows.retain(|_id, rec| {
        rec.abort.abort();
        count += 1;
        false
    });
    if count > 0 {
        warn!("tun2socks: registry watchdog closed {} TCP flows", count);
    }
    count
}

fn warn_capped(slot: &AtomicU64, msg: &str) {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let last = slot.load(Ordering::Relaxed);
    if now_ms.saturating_sub(last) >= 1000
        && slot
            .compare_exchange(last, now_ms, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
    {
        warn!("{}", msg);
    }
}

async fn abort_and_join(name: &str, handle: tokio::task::JoinHandle<()>) {
    handle.abort();
    if let Err(e) = handle.await {
        if !e.is_cancelled() {
            warn!("tun2socks: {name} task stopped with join error: {e}");
        }
    }
}

fn ingress_slot() -> &'static Mutex<Option<mpsc::Sender<Vec<u8>>>> {
    static S: OnceLock<Mutex<Option<mpsc::Sender<Vec<u8>>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// Weak handle to the per-engine `reply_readers` set, published by
/// `run_tun2socks` at startup. `Weak` so it never keeps the set alive past
/// an engine stop, and so a restart's fresh set simply replaces it. Read
/// only by `debug_counts`.
#[allow(clippy::type_complexity)]
fn reply_readers_slot(
) -> &'static Mutex<Option<std::sync::Weak<Mutex<HashSet<(SocketAddr, SocketAddr)>>>>> {
    static S: OnceLock<Mutex<Option<std::sync::Weak<Mutex<HashSet<(SocketAddr, SocketAddr)>>>>>> =
        OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// Live sizes of the per-flow state maps the slow-leak investigation
/// flagged (TCP flow registry, UDP reply-reader set, UDP NAT table), so the
/// harness `rss_monitor` can chart them next to RSS and pin which structure
/// grows under churn. All three reads are O(1)/O(shards) and only briefly
/// locked — cheap enough for a per-tick (≥5 s) sample.
#[derive(Debug, Default, Clone, Copy)]
pub struct DebugCounts {
    pub tcp_flows: u64,
    pub reply_readers: u64,
    pub nat_table: u64,
}

/// Snapshot [`DebugCounts`]. Returns zeros for any map whose owner isn't
/// currently running (engine stopped, tun2socks not started).
pub fn debug_counts() -> DebugCounts {
    DebugCounts {
        tcp_flows: tcp_flows().len() as u64,
        reply_readers: reply_readers_slot()
            .lock()
            .as_ref()
            .and_then(std::sync::Weak::upgrade)
            .map(|m| m.lock().len() as u64)
            .unwrap_or(0),
        nat_table: crate::engine::tunnel()
            .map(|t| t.inner().nat_table.len() as u64)
            .unwrap_or(0),
    }
}

pub fn start(ctx: *mut c_void, cb: WritePacketFn) -> Result<(), String> {
    if TUN2SOCKS_RUNNING.swap(true, Ordering::SeqCst) {
        return Err("tun2socks already running".into());
    }

    let emitter = EgressEmitter {
        ctx: EmitCtx(ctx),
        cb,
    };

    let my_gen = TUN2SOCKS_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    info!("tun2socks starting (direct-callback ingest, gen {my_gen})");

    let (ingress_tx, ingress_rx) = mpsc::channel::<Vec<u8>>(256);
    *ingress_slot().lock() = Some(ingress_tx);

    // Take the previous instance's handle so the new task can wait for its
    // teardown before touching the lwip globals.
    let prev = run_handle_slot().lock().take();

    let rt = crate::get_runtime();
    let handle = rt.spawn(async move {
        if let Some(prev) = prev {
            // `stop()` is fire-and-forget: the previous run task may still
            // be draining its channel or running its teardown. lwip's
            // global state (OUTPUT_CB_PTR, netif hooks, pcb lists) assumes
            // exactly one live NetStack, so wait for the old instance to
            // finish before building a new one. Packets that arrive meanwhile
            // buffer (then drop) in the ingress channel, which beats
            // corrupting the stack.
            if let Err(e) = prev.await {
                logging::bridge_log(&format!(
                    "tun2socks: previous instance stopped with join error: {e}"
                ));
            }
        }
        if let Err(e) = run_tun2socks(ingress_rx, emitter).await {
            logging::bridge_log(&format!("tun2socks error: {}", e));
        }
        // Generation-guarded cleanup: if a newer instance already started,
        // these globals belong to IT — clearing them here would sever the
        // live instance's ingest path and mark it not-running.
        if TUN2SOCKS_GEN.load(Ordering::SeqCst) == my_gen {
            ingress_slot().lock().take();
            TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
        }
        info!("tun2socks exited (gen {my_gen})");
    });
    *run_handle_slot().lock() = Some(handle);

    Ok(())
}

pub fn stop() {
    TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
    // Dropping the sender terminates the ingress task on its next `recv()`.
    // The run task's JoinHandle stays in `run_handle_slot` so the next
    // `start()` can await the teardown it triggers here.
    ingress_slot().lock().take();
}

/// Blocking shutdown: signal stop, then wait (bounded) for the run task to
/// fully tear down before returning.
///
/// The egress write callback can only be invoked from inside the run task —
/// its `egress` task is `abort_and_join`ed as part of `run_tun2socks`'s
/// teardown — so once this returns the FFI caller is guaranteed the callback
/// will never fire again and may safely release the egress `ctx` it passed to
/// [`start`].
///
/// [`stop`] alone is fire-and-forget: it only drops the ingress sender and
/// lowers the running flag, leaving the run task to drain on the runtime.
/// Swift's terminal `stop` `CFBridgingRelease`s the writer immediately after
/// the FFI returns, so without this join the still-draining egress task can
/// call the write callback on a freed Objective-C object — a use-after-free.
/// `suspendTun` deliberately keeps using [`stop`] because it does NOT release
/// the ctx (it is reused by the following `resumeTun`, whose `start` awaits
/// the previous teardown via `run_handle_slot`).
///
/// MUST be called from a NON-runtime thread (the Swift control queue): it
/// `block_on`s the shared runtime. Bounded by `JOIN_TIMEOUT` so a
/// pathological teardown hang can't freeze iOS's `stopTunnel` grace window;
/// if the bound trips we log and return anyway (a hung teardown is a separate
/// failure, and freezing shutdown is worse than a vanishingly-rare late
/// callback). Idempotent.
pub fn stop_blocking() {
    stop();
    let Some(handle) = run_handle_slot().lock().take() else {
        return;
    };
    const JOIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
    crate::get_runtime().block_on(async move {
        match tokio::time::timeout(JOIN_TIMEOUT, handle).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                logging::bridge_log(&format!("tun2socks: stop_blocking join error: {e}"));
            }
            Err(_) => {
                warn!(
                    "tun2socks: stop_blocking timed out after {:?}; run task still draining, releasing ctx anyway",
                    JOIN_TIMEOUT
                );
            }
        }
    });
}

/// Push a raw IP packet produced by `NEPacketTunnelFlow.readPackets` into the
/// netstack. Returns 0 on success, -1 if tun2socks isn't running or the queue
/// is closed. Swift-side flow-control lives inside the mpsc channel: when full
/// we drop rather than block, because `readPackets` must return promptly or
/// iOS starts queueing packets itself.
pub fn ingest(packet: &[u8]) -> i32 {
    let Some(tx) = ingress_slot().lock().clone() else {
        return -1;
    };
    match tx.try_send(packet.to_vec()) {
        Ok(()) => 0,
        Err(mpsc::error::TrySendError::Full(_)) => {
            logging::bridge_log("tun2socks: ingress queue full, dropping packet");
            0
        }
        Err(mpsc::error::TrySendError::Closed(_)) => -1,
    }
}

// ---------------------------------------------------------------------------
// Main tun2socks loop
//
// The Stack is NOT split. It implements Sink (ingress) and Stream (egress)
// behind a BiLock that deadlocks when used from two tasks. A single driver
// task owns the stack; other tasks exchange packets via mpsc channels.
// ---------------------------------------------------------------------------

async fn run_tun2socks(
    mut ingress_rx: mpsc::Receiver<Vec<u8>>,
    emitter: EgressEmitter,
) -> io::Result<()> {
    logging::bridge_log("tun2socks: building lwip netstack");

    let (mut stack, mut tcp_listener, udp_socket) =
        lwip::NetStack::with_buffer_size(1024, 256).map_err(|e| io::Error::other(e.to_string()))?;

    let (udp_write, mut udp_read) = udp_socket.split();

    let (udp_reply_tx, mut udp_reply_rx) = mpsc::channel::<UdpMsg>(256);
    // NAT key mirrors meow-tunnel's `NatTable = DashMap<(SocketAddr, SocketAddr), Arc<UdpSession>>`
    // post-ADR-0008 Direction-A refactor. We must key reader spawns on the
    // same tuple meow-tunnel uses, or dedupe breaks and we leak readers.
    let reply_readers: Arc<Mutex<HashSet<(SocketAddr, SocketAddr)>>> =
        Arc::new(Mutex::new(HashSet::new()));
    // Publish a weak handle so `debug_counts()` (harness RSS monitor) can
    // sample this set's size without owning it.
    *reply_readers_slot().lock() = Some(Arc::downgrade(&reply_readers));

    let (stack_ingress_tx, mut stack_ingress_rx) = mpsc::channel::<AnyIpPktFrame>(256);
    let (egress_tx, mut egress_rx) = mpsc::channel::<Vec<u8>>(1024);

    let udp_sem = Arc::new(Semaphore::new(UDP_BURST_CAP));
    let dns_sem = Arc::new(Semaphore::new(DNS_BURST_CAP));
    let tcp_accept_sem = Arc::new(Semaphore::new(accept_cap()));
    let tcp_flow_tasks = TaskTracker::new();

    let egress_tx_stack = egress_tx.clone();
    let stack_handle = tokio::spawn(async move {
        // This task is the single driver for BOTH directions of the lwip
        // stack — if it exits, every packet path (TCP, UDP, and eventually
        // the DNS intercept once stack_ingress fills) dies while the NE
        // process stays up and `ingest` keeps returning 0: a silent, total
        // traffic blackout that only a tunnel restart clears. So per-packet
        // errors are logged (capped) and the frame dropped; only channel
        // closure (tunnel shutdown) breaks the loop. See the 2026-06-06
        // after-hours-idle incident: a transient lwip ERR_MEM here used to
        // `break` and permanently wedge the tunnel.
        let send_err_last = AtomicU64::new(0);
        let recv_err_last = AtomicU64::new(0);
        loop {
            tokio::select! {
                pkt = stack_ingress_rx.recv() => {
                    match pkt {
                        Some(frame) => {
                            if let Err(e) = stack.send(frame).await {
                                warn_capped(
                                    &send_err_last,
                                    &format!("tun2socks: stack send error (frame dropped): {}", e),
                                );
                            }
                        }
                        None => break,
                    }
                }
                pkt = stack.next() => {
                    match pkt {
                        Some(Ok(frame)) => {
                            if egress_tx_stack.try_send(frame).is_err() {
                                warn_capped(
                                    &EGRESS_DROP_LOG_LAST_MS,
                                    "tun2socks: egress queue saturated, dropping outbound frame (Swift writePackets backpressure)",
                                );
                            }
                        }
                        Some(Err(e)) => {
                            warn_capped(
                                &recv_err_last,
                                &format!("tun2socks: stack recv error (ignored): {}", e),
                            );
                        }
                        None => break,
                    }
                }
            }
        }
    });

    let tcp_accept_sem_for_task = tcp_accept_sem.clone();
    let tcp_flow_tasks_for_accept = tcp_flow_tasks.clone();
    let tcp_accept_handle = tokio::spawn(async move {
        let cap_warn_last = AtomicU64::new(0);
        while let Some((stream, local_addr, remote_addr)) = tcp_listener.next().await {
            // Fake-IP mode: TCP DNS (rare, but RFC 1035 § 4.2.2 allows it
            // when a UDP reply was truncated) inside the TUN is
            // intentionally unsupported — iOS's stub resolver only falls
            // back to TCP/53 for very large replies, and our fake-IP A/AAAA
            // responses are tiny. Drop the stream so the kernel sees the
            // TCP session close; the client retries on UDP, which the
            // ingress loop intercepts.
            if remote_addr.port() == 53 {
                trace!(
                    "tun2socks: dropping in-TUN TCP/53 flow {} -> {} (UDP/53 intercept handles DNS)",
                    local_addr, remote_addr
                );
                drop(stream);
                continue;
            }
            // Cap backpressure: when no permit is immediately available the
            // registry is at the accept cap. Drop the incoming connection
            // rather than evicting an existing flow — existing flows are
            // doing useful work, and under a routing-loop storm (proxy
            // connections going back through the tunnel) evicting creates
            // more new connections that immediately hit the cap again,
            // corrupting lwip's PCB list with rapid back-to-back
            // tcp_abort calls (segfault / "tcp_poll: invalid pcb").
            //
            // The dropped stream sends a RST to the app-side socket,
            // which retries after the usual TCP backoff. Meanwhile,
            // existing flows drain naturally and free permits.
            let permit = match tcp_accept_sem_for_task.clone().try_acquire_owned() {
                Ok(p) => p,
                Err(tokio::sync::TryAcquireError::Closed) => break,
                Err(tokio::sync::TryAcquireError::NoPermits) => {
                    warn_capped(
                        &cap_warn_last,
                        "tun2socks: TCP accept cap full, dropping new connection",
                    );
                    tokio::spawn(async move { drop(stream) });
                    continue;
                }
            };
            // Per-accept logging was INFO; under burst (16k accepts in 600 s
            // measured in the VM stress run) the formatter + oslog writer
            // become a measurable cost. Trace level keeps it available for
            // dev diagnosis without paying the bytes on prod runs.
            trace!("tun2socks: TCP {} -> {}", local_addr, remote_addr);

            let flow_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
            let state = Arc::new(FlowState {
                last_active_ms: AtomicU64::new(now_ms()),
            });
            let state_for_task = state.clone();
            let task = tcp_flow_tasks_for_accept.spawn(async move {
                let _permit = permit;
                dispatch_tcp(stream, local_addr, remote_addr, state_for_task).await;
                tcp_flows().remove(&flow_id);
            });
            let abort = task.abort_handle();
            tcp_flows().insert(
                flow_id,
                FlowRecord {
                    state,
                    abort,
                    src: local_addr,
                    dst: remote_addr,
                },
            );
            if task.is_finished() {
                tcp_flows().remove(&flow_id);
            }
        }
    });

    let egress_handle = tokio::spawn(async move {
        while let Some(pkt) = egress_rx.recv().await {
            emitter.emit(&pkt);
        }
    });

    // Single writer task owns `UdpWriteHalf`; per-session readers feed it via
    // `udp_reply_tx`. Using an mpsc serializer avoids an Arc<Mutex<WriteHalf>>.
    let udp_writer_handle = tokio::spawn(async move {
        let udp_write = udp_write;
        // `udp_sendto` fails per-datagram (ERR_MEM under heap pressure,
        // ERR_RTE, …). Breaking here used to kill the reply path for every
        // UDP flow — QUIC, DNS-over-UDP upstreams, games — permanently,
        // while the tunnel otherwise looked alive. UDP is lossy by
        // contract: log (capped) and keep serving the next reply.
        let err_last = AtomicU64::new(0);
        while let Some(msg) = udp_reply_rx.recv().await {
            if let Err(e) = udp_write.send_to(&msg.0, &msg.1, &msg.2) {
                warn_capped(
                    &err_last,
                    &format!("tun2socks: UDP reply send error (datagram dropped): {}", e),
                );
            }
        }
    });

    let tcp_idle_sweeper_handle = tokio::spawn(run_tcp_idle_sweeper());

    let udp_reply_tx_accept = udp_reply_tx.clone();
    let reply_readers_accept = reply_readers.clone();
    let udp_sem_accept = udp_sem.clone();
    let udp_accept_handle = tokio::spawn(async move {
        while let Some((payload, src, dst)) = udp_read.next().await {
            let permit = match udp_sem_accept.clone().try_acquire_owned() {
                Ok(p) => p,
                Err(_) => {
                    warn_capped(
                        &UDP_CAP_LOG_LAST_MS,
                        "tun2socks: UDP live-session cap reached, dropping datagram",
                    );
                    continue;
                }
            };
            let reply_tx = udp_reply_tx_accept.clone();
            let readers = reply_readers_accept.clone();
            tokio::spawn(async move {
                dispatch_udp(payload, src, dst, reply_tx, readers, permit).await;
            });
        }
    });

    while let Some(ip_data) = ingress_rx.recv().await {
        if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
            break;
        }

        // Fake-IP mode: NEDNSSettings advertises a TUN-subnet IP
        // (172.19.0.2) as the system DNS server, so every UDP DNS query
        // arrives here as an in-TUN IP packet. Branch on qtype:
        //
        //   * AAAA (28)          → NOERROR-empty, unconditionally. Only the
        //     IPv4 fake-IP path is intercepted and proxied; stripping AAAA
        //     forces every client onto it.
        //   * A (1)              → meow's `DnsServer::handle_query`
        //     (fake-IP synthesis, reverse map, hosts, TTL).
        //   * anything else      → raw UDP forward to the pinned upstream
        //     pool (HTTPS, SVCB, TXT, MX, PTR, …). meow's DnsServer
        //     synthesises NXDOMAIN for non-A/AAAA, which kills iOS's
        //     HTTPS-record probe + ECH + Safari's modern connect path; the
        //     passthrough route lets those queries reach a real resolver.
        //
        // Never let the DNS packet touch the smoltcp stack — the
        // destination IP isn't a real host on the inside, and we'd just
        // create an orphan session.
        if parse_udp_packet(&ip_data).is_some_and(|p| p.dst_port == 53) {
            let permit = match dns_sem.clone().try_acquire_owned() {
                Ok(p) => p,
                Err(_) => {
                    warn_capped(
                        &DNS_CAP_LOG_LAST_MS,
                        "tun2socks: DNS burst cap reached, dropping query",
                    );
                    continue;
                }
            };
            let request = ip_data;
            let egress = egress_tx.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let work = async {
                    let Some(parsed) = parse_udp_packet(&request) else {
                        return;
                    };
                    let qtype = parse_dns_qtype(parsed.payload);

                    let response_payload = if qtype == Some(28) {
                        // AAAA is always answered NOERROR-empty without
                        // consulting the resolver, forcing every client onto
                        // A / fake-IPv4 — the only family the intercept
                        // actually proxies (the ::/0 claim is a deliberate
                        // sinkhole, not a working v6 path). The resolver's
                        // v4-only fake-IP pool already suppresses most AAAA,
                        // but its `hosts:` table is consulted before that
                        // suppression and can hand out real v6 addresses
                        // that would then bypass interception or fail to
                        // dial. Empty-answer (not a silent drop) so clients
                        // fall back to A immediately instead of waiting out
                        // resolver timeouts.
                        let Some(bytes) = dns_empty_response(parsed.payload) else {
                            return;
                        };
                        bytes
                    } else if qtype == Some(1) {
                        let Some(tunnel) = crate::engine::tunnel() else {
                            trace!("tun2socks: UDP/53 A query dropped — engine not yet running");
                            return;
                        };
                        let resolver = tunnel.resolver().clone();
                        match DnsServer::handle_query(parsed.payload, &resolver).await {
                            Ok(bytes) => bytes,
                            Err(e) => {
                                trace!("tun2socks: DnsServer::handle_query error: {}", e);
                                return;
                            }
                        }
                    } else {
                        // Non-A/AAAA: forward verbatim to the upstream pool,
                        // first response wins. Falls through to NXDOMAIN-shaped
                        // dropped reply if every upstream times out — better
                        // than meow's blanket NXDOMAIN, which actively
                        // misleads the client.
                        match forward_dns_to_upstream(
                            parsed.payload,
                            DNS_PASSTHROUGH_UPSTREAMS,
                            DNS_PASSTHROUGH_TIMEOUT,
                        )
                        .await
                        {
                            Some(bytes) => bytes,
                            None => {
                                trace!("tun2socks: DNS passthrough timed out (qtype={:?})", qtype);
                                return;
                            }
                        }
                    };
                    let Some(reply_pkt) = build_udp_reply(&request, &response_payload) else {
                        return;
                    };
                    // Match the rest of this file's "log, don't swallow" policy:
                    // a send error here means egress_rx was dropped (tunnel
                    // teardown), so the reply is lost. Surface it at trace so a
                    // shutdown-time DNS stall has an on-device signal instead of
                    // a silent discard.
                    if let Err(e) = egress.send(reply_pkt).await {
                        trace!(
                            "tun2socks: DNS reply egress send failed (egress closed?): {}",
                            e
                        );
                    }
                };
                if tokio::time::timeout(DNS_TASK_TIMEOUT, work).await.is_err() {
                    trace!(
                        "tun2socks: DNS task exceeded {:?}, aborting",
                        DNS_TASK_TIMEOUT
                    );
                }
            });
            continue;
        }

        match stack_ingress_tx.try_send(ip_data) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                // Never block the ingress loop on stack backpressure. Awaiting a
                // full stack queue stalls DNS interception and packet intake for
                // the entire tunnel, and can wedge against the single stack
                // driver when it is itself parked in `stack.send().await`
                // draining into lwip while egress can't drain (the 2026-06-06
                // blackout shape). Drop instead — TCP retransmits, and every
                // other saturation point in this file already drops rather than
                // blocks (ingest, egress, UDP cap, DNS cap).
                warn_capped(
                    &STACK_INGRESS_DROP_LOG_LAST_MS,
                    "tun2socks: stack ingress queue full, dropping inbound frame (stack driver backpressure)",
                );
            }
            Err(mpsc::error::TrySendError::Closed(_)) => break,
        }
    }

    // Await cancellation of lwIP-owning tasks before this outer generation
    // finishes. Dropping JoinHandles after `abort()` would detach those tasks,
    // letting the next `start()` build a fresh NetStack while old NetStack,
    // TcpListener, UdpSocket, or TcpStream drops are still mutating lwIP globals
    // on another runtime worker.
    abort_and_join("tcp accept", tcp_accept_handle).await;

    close_all_tcp_flows();
    tcp_flow_tasks.close();
    tcp_flow_tasks.wait().await;

    // UdpSocket::drop in the pinned lwip fork does not take LWIP_MUTEX, so keep
    // the socket alive until both possible concurrent users have stopped: the
    // UDP writer's send_to path and the stack driver's input/callback path.
    abort_and_join("udp writer", udp_writer_handle).await;
    abort_and_join("stack driver", stack_handle).await;
    abort_and_join("udp accept", udp_accept_handle).await;
    abort_and_join("egress", egress_handle).await;
    abort_and_join("tcp idle sweeper", tcp_idle_sweeper_handle).await;
    drop(udp_reply_tx);

    logging::bridge_log("tun2socks: exiting");
    Ok(())
}

// ---------------------------------------------------------------------------
// In-process TCP dispatch into meow_tunnel
// ---------------------------------------------------------------------------

/// RAII guard that decrements `ACTIVE_TCP_CONNS` on drop. Replaces the
/// manual `fetch_add` / `fetch_sub` pair so the counter stays balanced
/// when `dispatch_tcp` is dropped mid-`.await` — i.e. when the idle
/// sweeper, the registry watchdog, or the tunnel-shutdown loop calls
/// `FlowRecord::abort.abort()`. Without the guard, every aborted flow
/// leaked +1 on the counter, which is what users saw as a "1k+ active
/// connections" reading after hours of normal sweeper activity.
struct ActiveTcpGuard;

impl ActiveTcpGuard {
    fn new() -> Self {
        ACTIVE_TCP_CONNS.fetch_add(1, Ordering::Relaxed);
        Self
    }
}

impl Drop for ActiveTcpGuard {
    fn drop(&mut self) {
        ACTIVE_TCP_CONNS.fetch_sub(1, Ordering::Relaxed);
    }
}

async fn dispatch_tcp(
    stream: NetstackTcpStream,
    src: SocketAddr,
    dst: SocketAddr,
    state: Arc<FlowState>,
) {
    let _active = ActiveTcpGuard::new();
    let Some(tunnel) = crate::engine::tunnel() else {
        logging::bridge_log("tun2socks: engine not running, dropping TCP flow");
        return;
    };

    // No FFI-side fake-IP reverse: hand `dst.ip()` straight to meow with
    // an empty host. `meow_tunnel::tcp::handle_tcp` calls
    // `pre_handle_metadata` first, which consults the resolver's fake-IP
    // reverse table — if `dst.ip()` is inside the resolver's pool the
    // metadata is rewritten in place to `(host: <qname>, dst_ip: None)`
    // before rule matching, and if it isn't (literal-IP dial, fallback
    // answer, etc.) the rule engine matches on the literal IP. Either way
    // the FFI does not need its own pool.
    let metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Inner,
        src_ip: Some(src.ip()),
        src_port: src.port(),
        dst_ip: Some(dst.ip()),
        dst_port: dst.port(),
        host: String::new().into(),
        ..Default::default()
    };

    // Snapshot the FlowState's accept-time stamp before the relay future
    // even runs. `IdleTracking::touch` rewrites `last_active_ms` on the
    // first successful poll, which only happens after
    // `meow_tunnel::tcp::handle_tcp` → `pre_handle_metadata` →
    // `pre_resolve` → `proxy.dial_tcp` returns and `copy_bidirectional_buf`
    // starts reading. So "`last_active_ms` is still equal to the snapshot"
    // is a precise proxy for "the dial hasn't completed yet."
    let accepted_at_ms = state.last_active_ms.load(Ordering::Relaxed);
    let dial_deadline = DIAL_DEADLINE_MS.load(Ordering::Relaxed);
    let watchdog_state = state.clone();

    let local_eof = Arc::new(Notify::new());
    let conn: Box<dyn ProxyConn> = Box::new(IdleTracking {
        inner: NetstackConn(stream),
        state,
        local_eof: local_eof.clone(),
        eof_fired: AtomicBool::new(false),
    });

    // Race the normal relay against a local-FIN watcher. The relay
    // (`meow_tunnel::tcp::handle_tcp` → `copy_bidirectional_buf`)
    // already RFC-correctly half-closes: on local EOF it calls
    // `poll_shutdown` on the proxy outbound (sending FIN upstream) and
    // then waits for the upstream to FIN back to terminate.  That wait
    // hangs forever for long-poll / SSE / dead-peer flows and leaves
    // the proxy session, rustls state, NAT entry, and our task stack
    // alive until cap-pressure eviction picks it as the longest-idle flow.
    //
    // Instead: once the local read returns EOF, give the relay a brief
    // grace window to flush its outbound `poll_shutdown` cleanly, then
    // drop the future.  Dropping calls each transport layer's `Drop`,
    // which is what closes rustls (sends close_notify alert), tears
    // down the WebSocket framing, and drops the upstream TCP — clean
    // close semantics on every layer, just not waiting for the peer.
    //
    // `Statistics.connections` stays in sync because meow-tunnel's
    // `ConnectionGuard` is RAII and runs on the dropped future.
    let fut = meow_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata);
    tokio::pin!(fut);

    // Dial-deadline watchdog (see DIAL_DEADLINE_MS docs above and
    // `run_dial_watchdog` for the actual polling logic).
    // `watchdog_state` is moved into the watchdog; keep a handle to the same
    // FlowState so the local-FIN arm can watch download progress via
    // `last_active_ms` (bumped by `IdleTracking::poll_write` on each
    // downstream byte).
    let eof_state = watchdog_state.clone();
    let dial_watchdog = run_dial_watchdog(watchdog_state, accepted_at_ms, dial_deadline);
    tokio::pin!(dial_watchdog);

    tokio::select! {
        biased;
        _ = &mut fut => {}
        _ = local_eof.notified() => {
            // The app sent FIN. `handle_tcp` already half-closes correctly
            // (poll_shutdown upstream) and keeps the DOWNLOAD direction alive,
            // but then waits forever for the peer's FIN — which wedges
            // long-poll / SSE / dead-peer flows. Don't truncate a still-
            // flowing download with a fixed window (the old 250 ms drop):
            // extend the grace as long as downstream bytes keep arriving, and
            // give up only once the download side has been quiet for
            // HALF_CLOSE_IDLE_GRACE. A wedged/dead peer is dropped ~2 s after
            // FIN; a slow large response drains in full.
            loop {
                let before = eof_state.last_active_ms.load(Ordering::Relaxed);
                match tokio::time::timeout(HALF_CLOSE_IDLE_GRACE, &mut fut).await {
                    // Relay finished (peer FIN'd / closed) — clean done.
                    Ok(_) => break,
                    // No completion within the window. If a downstream byte
                    // landed (last_active_ms advanced) the response is still
                    // draining, so loop and extend; otherwise it's quiet —
                    // drop the future (RAII close on every layer).
                    Err(_) => {
                        if eof_state.last_active_ms.load(Ordering::Relaxed) == before {
                            break;
                        }
                    }
                }
            }
        }
        _ = &mut dial_watchdog => {
            warn!(
                "tun2socks: dial deadline exceeded for {} -> {} after {} ms; dropping flow",
                src, dst, dial_deadline,
            );
        }
    }
}

/// Dial-deadline watchdog body. Resolves when the per-flow dial has been
/// idle past the budget; parks forever once the relay starts so the
/// `select!` arm in `dispatch_tcp` lets the relay future own the rest of
/// the lifetime.
///
/// `dial_deadline_ms == 0` opts out (watchdog parks forever, behaviour
/// matches the pre-fix pipeline that relied solely on cap-pressure
/// eviction). Otherwise the watchdog ticks every 500 ms — fine grained
/// enough to make sub-second `dial_deadline_ms` settings (used by tests)
/// converge in <=2 ticks, coarse enough not to be a measurable wake-up
/// cost under steady state.
///
/// Factored out of `dispatch_tcp` so unit tests can drive it without
/// standing up the engine, netstack, and tcp-listener plumbing the
/// real call site requires. See the `dial_watchdog_*` tests at the
/// bottom of this file for the contract pinned in CI.
async fn run_dial_watchdog(state: Arc<FlowState>, accepted_at_ms: u64, dial_deadline_ms: u64) {
    if dial_deadline_ms == 0 {
        std::future::pending::<()>().await;
        return;
    }
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(dial_deadline_ms);
    loop {
        // 500 ms is the longest a sub-second deadline can wait without
        // overshooting the budget by more than one tick. Pick something
        // smaller (say 100 ms) only if test flakiness from the 500 ms
        // floor becomes a real issue.
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        if state.last_active_ms.load(Ordering::Relaxed) > accepted_at_ms {
            // Relay started — dial succeeded. Park; the relay future
            // now controls the task's lifetime.
            std::future::pending::<()>().await;
            return;
        }
        if tokio::time::Instant::now() >= deadline {
            // Final re-check to close the tick-to-deadline race: touch()
            // could have fired in the sleep wake-up between the load
            // above and the deadline check.
            if state.last_active_ms.load(Ordering::Relaxed) > accepted_at_ms {
                std::future::pending::<()>().await;
                return;
            }
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// ProxyConn newtype wrapper — orphan rules force a local impl for the netstack
// TCP stream. The wrapper only forwards AsyncRead / AsyncWrite; everything
// else takes the trait's defaults.
// ---------------------------------------------------------------------------

struct NetstackConn(NetstackTcpStream);

impl AsyncRead for NetstackConn {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl AsyncWrite for NetstackConn {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

impl ProxyConn for NetstackConn {
    fn remote_destination(&self) -> String {
        String::new()
    }
}

/// Wraps an `AsyncRead + AsyncWrite` to bump `FlowState::last_active_ms` on
/// every poll that returned `Ready(Ok(_))`. The stamp covers both directions
/// because the relay drives this end's `poll_read` (bytes from the app) and
/// `poll_write` (bytes from the upstream peer) on the same wrapper.
/// Pending / would-block polls are intentionally not counted as activity.
///
/// Generic over the inner stream so the idle-tracking semantics apply to
/// the meow path (`IdleTracking<NetstackConn>`, served as a
/// `Box<dyn ProxyConn>` to `meow_tunnel::tcp::handle_tcp`). Every TCP
/// flow goes through `meow_tunnel::tcp::handle_tcp`; there is no
/// alternate FFI-side bypass relay any more.
struct IdleTracking<T> {
    inner: T,
    state: Arc<FlowState>,
    /// Fires once when the inner stream's read side returns EOF (smoltcp
    /// transitioned to CLOSE_WAIT / CLOSED — the local endpoint sent FIN).
    /// `dispatch_tcp` waits on this in parallel with the relay so it can
    /// terminate the proxy outbound shortly after the local close instead
    /// of waiting for the upstream proxy to FIN back — which it may never
    /// do for long-poll / keepalive flows.
    local_eof: Arc<Notify>,
    /// Edge guard so we only fire `local_eof` once per stream lifetime,
    /// even if the relay re-polls a closed read end (it shouldn't, but
    /// `poll_read` returning `Ready(Ok(()))` with zero filled is the
    /// idle-poll fixed point and we don't want a wake-storm).
    eof_fired: AtomicBool,
}

impl<T> IdleTracking<T> {
    fn touch(&self) {
        self.state.last_active_ms.store(now_ms(), Ordering::Relaxed);
    }
}

impl<T: AsyncRead + Unpin> AsyncRead for IdleTracking<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
        match poll {
            Poll::Ready(Ok(())) => {
                let after = buf.filled().len();
                if after > before {
                    self.touch();
                } else if !self.eof_fired.swap(true, Ordering::Relaxed) {
                    // Zero-byte Ready means EOF (netstack-smoltcp signals
                    // this once the local socket reaches CLOSED). Wake up
                    // the dispatch_tcp select! arm that watches for it.
                    self.local_eof.notify_waiters();
                }
            }
            Poll::Ready(Err(_)) => {
                // Read errors out of the netstack stream (RST received,
                // smoltcp socket aborted, etc.) — treat the same as EOF
                // for the purposes of tearing down the proxy side.
                if !self.eof_fired.swap(true, Ordering::Relaxed) {
                    self.local_eof.notify_waiters();
                }
            }
            Poll::Pending => {}
        }
        poll
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for IdleTracking<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let poll = Pin::new(&mut self.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(n)) = poll {
            if n > 0 {
                self.touch();
            }
        }
        poll
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

// `ProxyConn` only matters on the meow path (the trait is consumed by
// `meow_tunnel::tcp::handle_tcp`); scope the impl to the netstack flavor
// so other future `IdleTracking<_>` instantiations don't have to invent a
// `remote_destination()` they wouldn't use.
impl ProxyConn for IdleTracking<NetstackConn> {
    fn remote_destination(&self) -> String {
        self.inner.remote_destination()
    }
}

// ---------------------------------------------------------------------------
// In-process UDP dispatch into meow_tunnel
//
// `meow_tunnel::udp::handle_udp` installs the outbound session into the NAT
// table on the first packet of a flow but does not drive the reply side — the
// caller owns the reader loop. We key replies on the same NAT key
// meow-tunnel uses internally (`"{src}:{remote_address}"`) so reader
// spawns stay deduped without a second source of truth.
// ---------------------------------------------------------------------------

async fn dispatch_udp(
    payload: Vec<u8>,
    src: SocketAddr,
    dst: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
    reply_readers: Arc<Mutex<HashSet<(SocketAddr, SocketAddr)>>>,
    permit: OwnedSemaphorePermit,
) {
    let Some(tunnel) = crate::engine::tunnel() else {
        logging::bridge_log("tun2socks: engine not running, dropping UDP datagram");
        return;
    };

    // No FFI-side fake-IP reverse: pass `dst.ip()` through and let meow's
    // `pre_handle_metadata` rewrite to the qname when the destination is
    // inside the resolver's fake-IP pool, exactly like the TCP path.
    let mut metadata = Metadata {
        network: Network::Udp,
        conn_type: ConnType::Inner,
        src_ip: Some(src.ip()),
        src_port: src.port(),
        dst_ip: Some(dst.ip()),
        dst_port: dst.port(),
        host: String::new().into(),
        ..Default::default()
    };

    // Mirror `handle_udp`'s prologue so the NAT key we compute here matches
    // exactly what handle_udp will insert into `nat_table`:
    //
    //   1. `pre_handle_metadata` — if `dst.ip()` is a fake-IP, this rewrites
    //      metadata to `(host: <qname>, dst_ip: None)`.
    //   2. `pre_resolve` — re-resolves the host (if any) through the engine
    //      resolver and re-populates `dst_ip` with the real upstream IP.
    //
    // Hold the `udp_sem` permit across the whole flow lifetime, not just the
    // dispatch window. `udp_sem` is a true *live-session* cap: it bounds the
    // number of simultaneously-live UDP flows (NAT entry + reply_readers entry
    // + reader task, each holding an `Arc<UdpSession>` + a 4 KiB buffer). The
    // idle-TTL sweeper only reaps flows that go quiet > 60 s; it does NOT bound
    // the count of *active* flows (QUIC, WebRTC, games, DNS fan-out, or a
    // source-port-fanning app), so without a count cap a workload that keeps N
    // flows each ≥1 datagram/idle-window alive grows monotonically toward the
    // ~50 MB jetsam cap. The permit is therefore MOVED into the reply-reader
    // task below and released only when that task exits and clears its NAT +
    // reply_readers state — so the permit population tracks the live-session
    // population exactly. On every early-return path here (resolve failure,
    // handle_udp bail, dedup hit) `permit` drops at end of scope, which is
    // correct: those paths create no live session.
    //
    // Both pre_* calls are idempotent — handle_udp invokes them again
    // internally and they short-circuit on the already-populated metadata.
    // The round-trip is unavoidable on this side because we need the
    // resolved SocketAddr to key the reply-reader registry.
    tunnel.inner().pre_handle_metadata(&mut metadata);
    tunnel.inner().pre_resolve(&mut metadata).await;
    let Some(resolved_ip) = metadata.dst_ip else {
        // Resolution failed — handle_udp will also bail, nothing to dispatch.
        return;
    };
    let key = (src, SocketAddr::new(resolved_ip, metadata.dst_port));

    meow_tunnel::udp::handle_udp(tunnel.inner(), &payload, src, metadata).await;

    if !reply_readers.lock().insert(key) {
        return;
    }

    let inner = tunnel.inner().clone();
    let Some(session) = inner.nat_table.get(&key).map(|r| r.value().clone()) else {
        // handle_udp bailed before NAT insert (no matching rule / dial error).
        reply_readers.lock().remove(&key);
        return;
    };

    spawn_udp_reply_reader(
        key,
        session,
        src,
        dst,
        reply_tx,
        reply_readers,
        inner,
        permit,
    );
}

/// Poll cadence for the post-first-reply UDP reply reader. Short so the reader
/// re-checks the bidirectional idle clock (which an outbound forward may have
/// just refreshed) promptly, without busy-spinning. Worst-case eviction
/// latency is `UDP_REPLY_IDLE_TTL + UDP_REPLY_POLL_INTERVAL`.
const UDP_REPLY_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

/// Both-directions-idle TTL after which the post-first-reply reply reader
/// evicts its session. Matches meow-tunnel's `DEFAULT_UDP_IDLE` (60 s) so the
/// FFI backstop and the NAT sweeper agree on when a session is dead.
const UDP_REPLY_IDLE_TTL: std::time::Duration = std::time::Duration::from_secs(60);

/// Forward one upstream→app UDP reply onto the shared writer channel.
///
/// A full `reply_tx` is treated as lossy packet drop (UDP semantics), NOT as a
/// reason to terminate the reply reader. Earlier this site did
/// `if reply_tx.try_send(msg).is_err() { break; }`, which tore the whole NAT
/// session + reader down on a single transient full queue: every subsequent
/// datagram on that 5-tuple then went through a full re-dispatch + re-dial
/// (fresh source port), and under multi-session bursts — where the single
/// shared writer is the bottleneck — that became a pathological
/// destroy-and-rebuild loop across every live session (online-gaming flows the
/// worst hit). Dropping the datagram instead keeps the session alive; a
/// genuinely dead session is still reaped by the first-reply deadline, the 60 s
/// idle backstop, and read errors. A blocking `send().await` is deliberately
/// avoided here: it would let one backed-up writer apply head-of-line
/// backpressure across the shared channel and stall every other session.
fn forward_udp_reply(reply_tx: &mpsc::Sender<UdpMsg>, msg: UdpMsg) {
    if reply_tx.try_send(msg).is_err() {
        warn_capped(
            &UDP_REPLY_DROP_LOG_LAST_MS,
            "tun2socks: UDP reply writer backed up, dropping datagram",
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn spawn_udp_reply_reader(
    key: (SocketAddr, SocketAddr),
    session: Arc<UdpSession>,
    app_src: SocketAddr,
    app_dst: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
    reply_readers: Arc<Mutex<HashSet<(SocketAddr, SocketAddr)>>>,
    tunnel_inner: Arc<TunnelInner>,
    permit: OwnedSemaphorePermit,
) {
    tokio::spawn(async move {
        // Hold the `udp_sem` permit for the entire reader lifetime so the
        // semaphore caps live sessions, not just the dispatch window. Released
        // (along with this flow's NAT + reply_readers entries) only when the
        // loop below breaks and the task returns.
        let _permit = permit;
        // Per-session reply buffer. Sized for the iOS TUN MTU (1500) plus
        // headroom for the rare oversized UDP datagram that survives path
        // fragmentation. Was 64 KiB — at N concurrent UDP sessions (DNS,
        // QUIC, NAT-traversal probes) that sums to N * 64 KiB pinned for
        // each session's idle lifetime, blowing past the 50 MB jetsam cap
        // long before meow's NAT timeout reaps the session. 4 KiB covers
        // every UDP datagram that can actually round-trip through a
        // 1500-MTU tun without fragmentation; oversized datagrams are
        // truncated at the read, which matches the on-wire reality.
        let mut buf = vec![0u8; 4 * 1024];
        // First-reply deadline: see UDP_FIRST_REPLY_DEADLINE_MS docs.
        // Only the *first* read is bounded — once a reply has come back
        // we know the route is alive and we don't want to evict an
        // active session on quiet idle periods (long-poll, NAT keepalive).
        let first_reply_deadline_ms = UDP_FIRST_REPLY_DEADLINE_MS.load(Ordering::Relaxed);
        let mut had_first_reply = false;
        'reader: loop {
            let read = if !had_first_reply && first_reply_deadline_ms > 0 {
                match tokio::time::timeout(
                    std::time::Duration::from_millis(first_reply_deadline_ms),
                    session.conn.read_packet(&mut buf),
                )
                .await
                {
                    Ok(res) => res,
                    Err(_) => {
                        warn!(
                            "UDP first-reply deadline exceeded for {:?} after {} ms; evicting session",
                            key, first_reply_deadline_ms,
                        );
                        break 'reader;
                    }
                }
            } else {
                // Post-first-reply idle backstop — BIDIRECTIONAL.
                //
                // The NAT sweeper (`spawn_background_tasks`) evicts the
                // `nat_table` entry once a session is idle > DEFAULT_UDP_IDLE
                // (60 s), but this reader task holds its OWN `Arc<UdpSession>`
                // + 4 KiB `buf`, so the sweeper alone can't unblock a
                // `read_packet` that never returns — the task would leak for
                // any session that gets one reply then goes silent.
                //
                // This used to bound each read at a flat 60 s and evict on
                // INBOUND silence alone, which diverged from the sweeper's
                // OUTBOUND-stamped clock: a session where the client keeps
                // sending (game input) while the server is briefly quiet > 60 s
                // got torn down here even though the NAT layer still considered
                // it active — forcing a re-dial on a fresh source port and
                // dropping in-flight replies. Instead, poll on a short interval
                // and evict only when BOTH directions have been idle for the
                // TTL: `idle_for()` reads the same `last_activity_ms` that
                // `handle_udp` bumps on every outbound forward AND that we now
                // bump on every inbound reply (touch() below). So an active
                // flow in EITHER direction keeps the reader alive; only a
                // genuinely two-way-silent session is reaped.
                loop {
                    match tokio::time::timeout(
                        UDP_REPLY_POLL_INTERVAL,
                        session.conn.read_packet(&mut buf),
                    )
                    .await
                    {
                        Ok(res) => break res,
                        Err(_) => {
                            if session.idle_for() >= UDP_REPLY_IDLE_TTL {
                                info!(
                                    "UDP reply reader idle (both directions) > {}s for {:?}; evicting session",
                                    UDP_REPLY_IDLE_TTL.as_secs(),
                                    key
                                );
                                break 'reader;
                            }
                            // Outbound-active: the shared clock was refreshed
                            // elsewhere, so keep polling for inbound replies.
                        }
                    }
                }
            };
            match read {
                Ok((n, _from)) => {
                    had_first_reply = true;
                    // Inbound traffic is activity too: refresh the shared NAT
                    // idle clock so neither the sweeper nor the backstop above
                    // evicts a receive-active / send-quiet session while data
                    // is still arriving.
                    session.touch();
                    // Reply injection: the IP frame handed back to the app
                    // must look like it came FROM the external peer (app_dst)
                    // TO the app (app_src). netstack's Sink builds the header
                    // from (src, dst) in that argument order.
                    let msg: UdpMsg = (buf[..n].to_vec(), app_dst, app_src);
                    forward_udp_reply(&reply_tx, msg);
                }
                Err(e) => {
                    info!("UDP reply reader closing for {:?}: {}", key, e);
                    break 'reader;
                }
            }
        }
        tunnel_inner.nat_table.remove(&key);
        reply_readers.lock().remove(&key);
    });
}

// ---------------------------------------------------------------------------
// DNS passthrough — for qtypes meow's resolver doesn't synthesise (anything
// other than A / AAAA) we forward the raw query to one of the pinned
// upstream resolvers and inject the reply back. Mirrors the upstream pool in
// `engine::pinned_dns_block` (CN-side, no anycast) so that split-horizon
// answers are consistent across the A/AAAA and HTTPS/SVCB/TXT paths.
// ---------------------------------------------------------------------------

/// Pinned UDP/53 upstream pool used for non-A/AAAA passthrough. Kept in
/// sync with `engine::pinned_dns_block`'s nameserver list; if you add or
/// remove a CN nameserver there, mirror it here.
const DNS_PASSTHROUGH_UPSTREAMS: &[&str] = &["119.29.29.29:53", "223.5.5.5:53"];

/// Per-attempt deadline before we give up on the whole upstream pool. iOS
/// clients retry on their own when no reply comes back — we'd rather drop
/// the response than hold a `tokio::spawn` task open indefinitely against
/// a dead upstream.
const DNS_PASSTHROUGH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Read the qtype from the first question of a DNS query payload. Returns
/// `None` for malformed packets (truncation, missing terminator). Handles
/// the RFC-1035 §4.1.4 message-compression pointer encoding (top two bits
/// of the length octet set → 16-bit pointer back into the message)
/// because some clients send a compressed query name even though it's the
/// first occurrence — overly defensive but cheap.
pub(crate) fn parse_dns_qtype(payload: &[u8]) -> Option<u16> {
    if payload.len() < 12 {
        return None;
    }
    let qdcount = u16::from_be_bytes([payload[4], payload[5]]);
    if qdcount == 0 {
        return None;
    }
    let mut pos = 12usize;
    loop {
        let len = *payload.get(pos)? as usize;
        if len == 0 {
            pos = pos.checked_add(1)?;
            break;
        }
        if len & 0xC0 == 0xC0 {
            // Compression pointer is a 2-byte field; qtype follows the
            // pointer (we don't need to chase the pointer for qtype).
            pos = pos.checked_add(2)?;
            break;
        }
        pos = pos.checked_add(1 + len)?;
    }
    let hi = *payload.get(pos)?;
    let lo = *payload.get(pos.checked_add(1)?)?;
    Some(u16::from_be_bytes([hi, lo]))
}

/// Build a NOERROR response with zero answers for `query`, echoing its ID,
/// RD flag, and question section. Used to strip every AAAA query: an empty
/// answer makes clients fall back to A immediately, where a silent drop
/// would stall them for the full resolver timeout (and NXDOMAIN would
/// negative-cache against the whole name, poisoning the A lookup too —
/// same rationale as meow-dns upstream).
///
/// `None` if `query` is malformed (shorter than a header, or truncated
/// inside the first question).
pub(crate) fn dns_empty_response(query: &[u8]) -> Option<Vec<u8>> {
    if query.len() < 12 {
        return None;
    }
    // Walk the first question (same qname walk as parse_dns_qtype) to find
    // its end, then truncate there: echoing the original tail with zeroed
    // section counts would leave orphaned EDNS/additional bytes.
    let mut pos = 12usize;
    loop {
        let len = *query.get(pos)? as usize;
        if len == 0 {
            pos = pos.checked_add(1)?;
            break;
        }
        if len & 0xC0 == 0xC0 {
            pos = pos.checked_add(2)?;
            break;
        }
        pos = pos.checked_add(1 + len)?;
    }
    let question_end = pos.checked_add(4)?; // qtype + qclass
    if query.len() < question_end {
        return None;
    }
    let mut resp = query[..question_end].to_vec();
    resp[2] |= 0x80; // QR = response (keeps opcode + RD as sent)
    resp[2] &= !0x02; // clear TC
    resp[3] = 0x80; // RA set, Z/AD/CD cleared, RCODE = NOERROR
    resp[4] = 0; // QDCOUNT = 1 — only the first question is echoed
    resp[5] = 1;
    resp[6..12].fill(0); // ANCOUNT / NSCOUNT / ARCOUNT = 0
    Some(resp)
}

/// Forward `query` verbatim to each upstream in parallel, return the
/// first reply whose 16-bit DNS ID matches the query. `None` if every
/// upstream times out, errors, or replies with a mismatched ID.
///
/// Uses a fresh ephemeral UDP socket per upstream; iOS extension sockets
/// bypass the tunnel by default so the dial reaches the real upstream
/// over the device's underlying network interface rather than looping
/// back into the tun's UDP/53 intercept.
pub(crate) async fn forward_dns_to_upstream(
    query: &[u8],
    upstreams: &[&str],
    timeout: std::time::Duration,
) -> Option<Vec<u8>> {
    if upstreams.is_empty() || query.len() < 2 {
        return None;
    }
    let query_id = u16::from_be_bytes([query[0], query[1]]);
    let query_shared: Arc<[u8]> = Arc::from(query);

    type DnsForwardFut = Pin<Box<dyn std::future::Future<Output = Option<Vec<u8>>> + Send>>;
    let mut futs: Vec<DnsForwardFut> = Vec::with_capacity(upstreams.len());
    for upstream in upstreams {
        let Ok(addr) = upstream.parse::<SocketAddr>() else {
            continue;
        };
        let q = query_shared.clone();
        futs.push(Box::pin(async move {
            let socket = tokio::net::UdpSocket::bind(("0.0.0.0", 0u16)).await.ok()?;
            // `connect` pins the socket to this upstream so the kernel delivers
            // only datagrams whose source is `addr`. Without it, `recv_from`
            // accepts a reply from ANY source: an off-path attacker who forges
            // the upstream's src IP/port and guesses the 16-bit transaction ID
            // could race a spoofed answer in ahead of the real resolver, and
            // ID-matching alone would accept it. connect() closes that hole and
            // also lets the OS surface ICMP port-unreachable as a recv error.
            socket.connect(addr).await.ok()?;
            socket.send(&q).await.ok()?;
            let mut buf = [0u8; 1500];
            let recv = tokio::time::timeout(timeout, socket.recv(&mut buf)).await;
            let n = recv.ok()?.ok()?;
            if n >= 2 && u16::from_be_bytes([buf[0], buf[1]]) == query_id {
                Some(buf[..n].to_vec())
            } else {
                None
            }
        }));
    }
    while !futs.is_empty() {
        let (result, _idx, remaining) = futures::future::select_all(futs).await;
        if result.is_some() {
            return result;
        }
        futs = remaining;
    }
    None
}

// ---------------------------------------------------------------------------
// UDP helpers — minimal IPv4/UDP parser used to identify in-TUN DNS traffic
// (UDP/53) so it can be dropped pre-stack. See ingress loop in `run_tun2socks`.
// ---------------------------------------------------------------------------

/// Build a UDP-over-IPv4 reply for a captured DNS query: swap src/dst
/// addresses + ports, drop in `reply_payload`, leave the UDP checksum at 0
/// (legal for IPv4, per RFC 768) and recompute the IPv4 header checksum.
/// Returns `None` if the input isn't a parseable IPv4/UDP packet.
fn build_udp_reply(orig_ip_data: &[u8], reply_payload: &[u8]) -> Option<Vec<u8>> {
    if orig_ip_data.len() < 28 || (orig_ip_data[0] >> 4) != 4 || orig_ip_data[9] != 17 {
        return None;
    }
    let ihl = (orig_ip_data[0] & 0x0F) as usize * 4;
    if ihl < 20 || orig_ip_data.len() < ihl + 8 {
        return None;
    }
    // Drop any IPv4 options on the reply (no client needs them on a DNS
    // response). Fixed 20-byte header + 8-byte UDP header + payload.
    let total_len = 20u16
        .checked_add(8)
        .and_then(|n| n.checked_add(u16::try_from(reply_payload.len()).ok()?))?;
    let udp_len = 8u16.checked_add(u16::try_from(reply_payload.len()).ok()?)?;

    let mut pkt = Vec::with_capacity(usize::from(total_len));
    pkt.push(0x45); // version=4, IHL=5
    pkt.push(0x00); // DSCP/ECN
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]); // identification (0 is fine for stateless replies)
    pkt.extend_from_slice(&[0x40, 0x00]); // flags=DF, fragment offset=0
    pkt.push(64); // TTL
    pkt.push(17); // protocol = UDP
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder, filled in below
    pkt.extend_from_slice(&orig_ip_data[16..20]); // new src IP = original dst
    pkt.extend_from_slice(&orig_ip_data[12..16]); // new dst IP = original src

    // IPv4 header checksum over the just-written 20 bytes.
    let cksum = ipv4_header_checksum(&pkt[0..20]);
    pkt[10..12].copy_from_slice(&cksum.to_be_bytes());

    // UDP header — swap ports, length, checksum=0.
    pkt.extend_from_slice(&orig_ip_data[ihl + 2..ihl + 4]); // new src port = original dst port (53)
    pkt.extend_from_slice(&orig_ip_data[ihl..ihl + 2]); // new dst port = original src port
    pkt.extend_from_slice(&udp_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]); // UDP checksum = 0 (RFC 768, legal on IPv4)
    pkt.extend_from_slice(reply_payload);
    Some(pkt)
}

/// One's-complement sum over a 20-byte IPv4 header. Caller has already
/// zeroed the checksum field at bytes 10..12.
fn ipv4_header_checksum(header: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for chunk in header.chunks_exact(2) {
        sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

/// Parsed view of an IPv4 + UDP packet. Returned by [`parse_udp_packet`]; the
/// `payload` borrow ties back to the caller's `ip_data` slice. Named fields
/// avoid the positional-tuple footgun that hid the `from_ne_bytes` bug in
/// FI-1: the UDP/53 intercept only consumed `dst_port`, so an endian flip in
/// the IP fields wasn't visible at the call site.
struct ParsedUdp<'a> {
    #[allow(dead_code)] // reserved for future callers (NAT-style src logging)
    src_ip: u32,
    #[allow(dead_code)]
    src_port: u16,
    #[allow(dead_code)]
    dst_ip: u32,
    dst_port: u16,
    payload: &'a [u8],
}

fn parse_udp_packet(ip_data: &[u8]) -> Option<ParsedUdp<'_>> {
    if ip_data.len() < 28 {
        return None;
    }
    if (ip_data[0] >> 4) != 4 {
        return None;
    }
    if ip_data[9] != 17 {
        return None;
    }
    let ihl = (ip_data[0] & 0x0F) as usize * 4;
    if ip_data.len() < ihl + 8 {
        return None;
    }
    // IPv4 addresses are on-wire big-endian; decode accordingly so the
    // resulting `u32` matches `Ipv4Addr::from(u32)` semantics on every host.
    let src_ip = u32::from_be_bytes([ip_data[12], ip_data[13], ip_data[14], ip_data[15]]);
    let dst_ip = u32::from_be_bytes([ip_data[16], ip_data[17], ip_data[18], ip_data[19]]);
    let src_port = u16::from_be_bytes([ip_data[ihl], ip_data[ihl + 1]]);
    let dst_port = u16::from_be_bytes([ip_data[ihl + 2], ip_data[ihl + 3]]);
    let udp_len = u16::from_be_bytes([ip_data[ihl + 4], ip_data[ihl + 5]]) as usize;
    let start = ihl + 8;
    let end = (ihl + udp_len).min(ip_data.len());
    if start > end {
        return None;
    }
    Some(ParsedUdp {
        src_ip,
        src_port,
        dst_ip,
        dst_port,
        payload: &ip_data[start..end],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use std::sync::Mutex as StdMutex;

    /// Hand-built IPv4 + UDP packet: src 10.0.0.7:54321 → dst 172.19.0.2:53,
    /// payload "QQQQ". 20-byte IPv4 header + 8-byte UDP header + 4-byte
    /// payload = 32 bytes total. Used by the build_udp_reply tests below.
    fn synthetic_dns_query_packet() -> Vec<u8> {
        let mut pkt = Vec::new();
        // IPv4 header
        pkt.extend_from_slice(&[
            0x45, 0x00, 0x00, 0x20, 0x12, 0x34, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00, 10, 0, 0, 7,
            172, 19, 0, 2,
        ]);
        // UDP header: src port 54321, dst port 53, length 12, checksum 0
        pkt.extend_from_slice(&[0xD4, 0x31, 0x00, 0x35, 0x00, 0x0C, 0x00, 0x00]);
        // payload
        pkt.extend_from_slice(b"QQQQ");
        pkt
    }

    /// Build a minimal DNS query payload (header + one question) for a
    /// given qname + qtype. No EDNS, no compression, IN class.
    fn dns_query(qname: &str, qtype: u16) -> Vec<u8> {
        let mut pkt = Vec::new();
        pkt.extend_from_slice(&[0xAB, 0xCD]); // ID = 0xABCD
        pkt.extend_from_slice(&[0x01, 0x00]); // standard query, RD set
        pkt.extend_from_slice(&[0x00, 0x01]); // QDCOUNT = 1
        pkt.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // AN/NS/AR = 0
        for label in qname.split('.') {
            pkt.push(label.len() as u8);
            pkt.extend_from_slice(label.as_bytes());
        }
        pkt.push(0x00); // qname terminator
        pkt.extend_from_slice(&qtype.to_be_bytes()); // QTYPE
        pkt.extend_from_slice(&[0x00, 0x01]); // QCLASS = IN
        pkt
    }

    #[test]
    fn parse_qtype_recognises_a() {
        let pkt = dns_query("example.com", 1);
        assert_eq!(parse_dns_qtype(&pkt), Some(1));
    }

    #[test]
    fn parse_qtype_recognises_aaaa() {
        let pkt = dns_query("example.com", 28);
        assert_eq!(parse_dns_qtype(&pkt), Some(28));
    }

    #[test]
    fn dns_empty_response_echoes_question_with_zero_answers() {
        let query = dns_query("v6.example.com", 28);
        let resp = dns_empty_response(&query).expect("well-formed query");
        // ID echoed
        assert_eq!(&resp[0..2], &query[0..2]);
        // QR set, opcode QUERY, RD preserved, TC clear
        assert_eq!(resp[2], 0x81);
        // RA set, RCODE NOERROR
        assert_eq!(resp[3], 0x80);
        // QDCOUNT 1, AN/NS/AR 0
        assert_eq!(&resp[4..12], &[0, 1, 0, 0, 0, 0, 0, 0]);
        // question section echoed verbatim, nothing after it
        assert_eq!(&resp[12..], &query[12..]);
        assert_eq!(parse_dns_qtype(&resp), Some(28));
    }

    #[test]
    fn dns_empty_response_truncates_edns_additional_section() {
        let mut query = dns_query("a.example.com", 28);
        // Append a minimal EDNS0 OPT record and bump ARCOUNT.
        query[11] = 1;
        query.extend_from_slice(&[0x00, 0x00, 0x29, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
        let bare_len = dns_query("a.example.com", 28).len();
        let resp = dns_empty_response(&query).expect("well-formed query");
        assert_eq!(resp.len(), bare_len, "OPT record must be truncated");
        assert_eq!(resp[11], 0, "ARCOUNT must be zeroed");
    }

    #[test]
    fn dns_empty_response_rejects_truncated_query() {
        assert!(dns_empty_response(&[0u8; 5]).is_none());
        let query = dns_query("example.com", 28);
        assert!(dns_empty_response(&query[..query.len() - 3]).is_none());
    }

    #[test]
    fn parse_qtype_recognises_https() {
        // qtype 65 (HTTPS RR, RFC 9460) — the iOS-Safari modern probe
        // that motivated the passthrough path.
        let pkt = dns_query("xhscdn.com", 65);
        assert_eq!(parse_dns_qtype(&pkt), Some(65));
    }

    #[test]
    fn parse_qtype_recognises_svcb_and_txt_and_mx_and_ptr() {
        for qtype in [12u16, 15, 16, 64] {
            let pkt = dns_query("a.b.c", qtype);
            assert_eq!(parse_dns_qtype(&pkt), Some(qtype));
        }
    }

    #[test]
    fn parse_qtype_handles_compression_pointer_in_qname() {
        // Synthetic: qname is a 2-byte compression pointer (0xC0 0x0C →
        // points back to offset 12, the original qname). Some clients
        // emit this even though pointers in queries are pathological;
        // the parser must skip the 2-byte field and read qtype after.
        let mut pkt = Vec::new();
        pkt.extend_from_slice(&[0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01]);
        pkt.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
        pkt.extend_from_slice(&[0xC0, 0x0C]); // compression pointer "qname"
        pkt.extend_from_slice(&[0x00, 0x41]); // qtype = 65 (HTTPS)
        pkt.extend_from_slice(&[0x00, 0x01]); // qclass = IN
        assert_eq!(parse_dns_qtype(&pkt), Some(65));
    }

    #[test]
    fn parse_qtype_rejects_short_packet() {
        assert_eq!(parse_dns_qtype(&[]), None);
        assert_eq!(parse_dns_qtype(&[0; 11]), None);
    }

    #[test]
    fn parse_qtype_rejects_zero_qdcount() {
        let mut pkt = dns_query("a.b", 1);
        pkt[4] = 0;
        pkt[5] = 0; // QDCOUNT = 0
        assert_eq!(parse_dns_qtype(&pkt), None);
    }

    #[test]
    fn parse_qtype_rejects_truncated_qname() {
        // Length octet promises 32 bytes but the buffer ends right after.
        let pkt = vec![
            0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, b'x',
        ];
        assert_eq!(parse_dns_qtype(&pkt), None);
    }

    #[tokio::test]
    async fn forward_dns_returns_first_matching_reply() {
        // Spin up a tiny UDP echo "resolver" that just rewrites the QR
        // bit and sends back the query verbatim — close enough for the
        // ID-match contract this function enforces.
        let listener = tokio::net::UdpSocket::bind(("127.0.0.1", 0u16))
            .await
            .expect("bind echo");
        let upstream = format!("{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 1500];
            if let Ok((n, src)) = listener.recv_from(&mut buf).await {
                buf.truncate(n);
                if buf.len() >= 3 {
                    buf[2] |= 0x80; // set QR (response) bit
                }
                let _ = listener.send_to(&buf, src).await;
            }
        });
        let query = dns_query("example.com", 65);
        let reply = forward_dns_to_upstream(
            &query,
            &[upstream.as_str()],
            std::time::Duration::from_secs(2),
        )
        .await
        .expect("upstream replied");
        // ID echoed back, QR bit now set.
        assert_eq!(&reply[0..2], &query[0..2]);
        assert_eq!(reply[2] & 0x80, 0x80, "response bit set");
    }

    #[tokio::test]
    async fn forward_dns_times_out_when_upstream_drops() {
        // Bind a socket but never read — every send will sit unanswered.
        let listener = tokio::net::UdpSocket::bind(("127.0.0.1", 0u16))
            .await
            .expect("bind sink");
        let upstream = format!("{}", listener.local_addr().unwrap());
        let query = dns_query("example.com", 65);
        let reply = forward_dns_to_upstream(
            &query,
            &[upstream.as_str()],
            std::time::Duration::from_millis(120),
        )
        .await;
        assert!(reply.is_none(), "expected timeout, got {:?}", reply);
    }

    #[test]
    fn build_udp_reply_swaps_addresses_and_ports() {
        let req = synthetic_dns_query_packet();
        let reply = build_udp_reply(&req, b"OK").expect("reply built");
        // Total length = 20 + 8 + 2 = 30
        assert_eq!(u16::from_be_bytes([reply[2], reply[3]]), 30);
        assert_eq!(reply[9], 17, "protocol stays UDP");
        // src IP = original dst, dst IP = original src
        assert_eq!(&reply[12..16], &[172, 19, 0, 2]);
        assert_eq!(&reply[16..20], &[10, 0, 0, 7]);
        // src port = original dst (53), dst port = original src (54321)
        assert_eq!(&reply[20..22], &[0x00, 0x35]);
        assert_eq!(&reply[22..24], &[0xD4, 0x31]);
        // UDP length = 8 + 2
        assert_eq!(u16::from_be_bytes([reply[24], reply[25]]), 10);
        assert_eq!(&reply[28..30], b"OK");
    }

    #[test]
    fn build_udp_reply_ipv4_checksum_is_valid() {
        let req = synthetic_dns_query_packet();
        let reply = build_udp_reply(&req, b"OK").expect("reply built");
        // A correct IPv4 header sums to 0xFFFF in one's-complement, so the
        // verifier returns 0 (i.e. our recomputed checksum is itself
        // unchanged when fed back through `ipv4_header_checksum`).
        let mut header = reply[0..20].to_vec();
        let stored = u16::from_be_bytes([header[10], header[11]]);
        header[10] = 0;
        header[11] = 0;
        assert_eq!(ipv4_header_checksum(&header), stored);
    }

    #[test]
    fn build_udp_reply_rejects_non_udp_input() {
        let mut pkt = synthetic_dns_query_packet();
        pkt[9] = 6; // protocol = TCP
        assert!(build_udp_reply(&pkt, b"x").is_none());
    }

    /// Regression for FI-1: `parse_udp_packet` previously used
    /// `from_ne_bytes` for the src/dst IP fields, returning host-endian
    /// garbage on little-endian targets (i.e. every Apple-Silicon and x86_64
    /// device this ships on). The bug was latent because the only call site
    /// consumes `dst_port`, but anything that decoded the u32 back via
    /// `Ipv4Addr::from` would have seen reversed octets. Pin the on-wire
    /// big-endian decode here so a future regression trips this test.
    #[test]
    fn parse_udp_packet_decodes_ipv4_wire_form_big_endian() {
        let pkt = synthetic_dns_query_packet();
        let parsed = parse_udp_packet(&pkt).expect("packet parses");
        // synthetic_dns_query_packet() builds src 10.0.0.7:54321 and
        // dst 172.19.0.2:53. After big-endian decoding the u32s must round
        // -trip back to those Ipv4Addrs.
        assert_eq!(Ipv4Addr::from(parsed.src_ip), Ipv4Addr::new(10, 0, 0, 7));
        assert_eq!(Ipv4Addr::from(parsed.dst_ip), Ipv4Addr::new(172, 19, 0, 2));
        assert_eq!(parsed.src_port, 54321);
        assert_eq!(parsed.dst_port, 53);
        assert_eq!(parsed.payload, b"QQQQ");
    }

    /// Regression: a momentarily-full reply-writer channel must DROP the
    /// datagram (UDP is lossy) and leave the reply reader running — a full
    /// queue is transient backpressure, not a dead flow. Before this fix the
    /// reader did `if reply_tx.try_send(msg).is_err() { break; }`, so a single
    /// full-queue hiccup tore down the whole NAT session and forced a re-dial
    /// (fresh source port) on the next datagram — a destroy-and-rebuild loop
    /// under burst that broke long-lived UDP apps (online gaming).
    /// `forward_udp_reply` must absorb the full-channel case as a drop and stay
    /// usable afterwards.
    #[test]
    fn forward_udp_reply_drops_when_full_without_terminating() {
        let src = SocketAddr::from((Ipv4Addr::new(10, 0, 0, 1), 5000));
        let dst = SocketAddr::from((Ipv4Addr::new(1, 1, 1, 1), 443));

        // Capacity-1 channel; the first forward fills the only slot.
        let (tx, mut rx) = mpsc::channel::<UdpMsg>(1);
        forward_udp_reply(&tx, (vec![1u8], dst, src));

        // Second forward hits a full channel. The pre-fix code signalled
        // teardown here; the helper must simply drop the datagram and return.
        forward_udp_reply(&tx, (vec![2u8], dst, src));

        let first = rx.try_recv().expect("first datagram delivered");
        assert_eq!(first.0, vec![1u8]);
        assert!(
            rx.try_recv().is_err(),
            "second datagram must be dropped, not queued behind the first"
        );

        // The channel is still open and usable — i.e. the session was NOT torn
        // down by the full-queue drop. A drained slot accepts the next reply.
        forward_udp_reply(&tx, (vec![3u8], dst, src));
        let third = rx.try_recv().expect("post-drop datagram still deliverable");
        assert_eq!(third.0, vec![3u8]);
    }

    /// All tests in this module mutate the process-wide `tcp_flows()`
    /// registry. Default `cargo test` parallelism races them; serialize
    /// through a single guard so they observe a clean slate.
    fn flows_test_guard() -> std::sync::MutexGuard<'static, ()> {
        static GUARD: StdMutex<()> = StdMutex::new(());
        GUARD.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Serializes the lifecycle tests that drive the process-global tun2socks
    /// start/stop state (`TUN2SOCKS_RUNNING`, `ingress_slot`, `run_handle_slot`).
    /// Default `cargo test` parallelism would otherwise let one test's `start()`
    /// observe another's still-running instance and fail with "already running".
    fn lifecycle_test_guard() -> std::sync::MutexGuard<'static, ()> {
        static GUARD: StdMutex<()> = StdMutex::new(());
        GUARD.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn dummy_addr(port: u16) -> SocketAddr {
        SocketAddr::new(std::net::IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), port)
    }

    /// Spawns a no-op task purely so we have a real `AbortHandle` to put in
    /// `FlowRecord`. We don't care if abort actually fires.
    fn dummy_handle() -> tokio::task::AbortHandle {
        tokio::runtime::Handle::current()
            .spawn(std::future::pending::<()>())
            .abort_handle()
    }

    #[tokio::test]
    async fn evict_oldest_picks_longest_idle_flow() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();

        let now = now_ms();
        let stale_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
        let fresh_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);

        flows.insert(
            stale_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now.saturating_sub(60_000)),
                }),
                abort: dummy_handle(),
                src: dummy_addr(1),
                dst: dummy_addr(2),
            },
        );
        flows.insert(
            fresh_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now),
                }),
                abort: dummy_handle(),
                src: dummy_addr(3),
                dst: dummy_addr(4),
            },
        );

        let evicted = evict_oldest_idle_tcp_flow();
        assert_eq!(
            evicted,
            Some(stale_id),
            "longest-idle flow should be evicted"
        );
        assert!(flows.get(&stale_id).is_none(), "stale flow removed");
        assert!(flows.get(&fresh_id).is_some(), "fresh flow retained");

        flows.clear();
    }

    #[tokio::test]
    async fn evict_oldest_with_no_flows_is_a_no_op() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();
        assert_eq!(evict_oldest_idle_tcp_flow(), None);
    }

    #[tokio::test]
    async fn close_all_with_no_flows_is_a_no_op() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();
        assert_eq!(close_all_tcp_flows(), 0);
    }

    #[tokio::test]
    async fn active_tcp_guard_balances_on_drop_and_panic() {
        // Snapshot, then exercise the guard through both a normal scope-exit
        // and a panic-unwind. Both must restore the counter to its baseline.
        let baseline = ACTIVE_TCP_CONNS.load(Ordering::Relaxed);

        {
            let _g = ActiveTcpGuard::new();
            assert_eq!(
                ACTIVE_TCP_CONNS.load(Ordering::Relaxed),
                baseline + 1,
                "guard increments on construction"
            );
        }
        assert_eq!(
            ACTIVE_TCP_CONNS.load(Ordering::Relaxed),
            baseline,
            "guard decrements on scope exit"
        );

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _g = ActiveTcpGuard::new();
            panic!("simulating mid-flow abort");
        }));
        assert!(result.is_err(), "panic should propagate");
        assert_eq!(
            ACTIVE_TCP_CONNS.load(Ordering::Relaxed),
            baseline,
            "guard decrements even when the holding scope unwinds"
        );
    }

    #[tokio::test]
    async fn close_all_clears_every_flow_regardless_of_freshness() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();

        let now = now_ms();
        let stale_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
        let fresh_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);

        flows.insert(
            stale_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now.saturating_sub(60_000)),
                }),
                abort: dummy_handle(),
                src: dummy_addr(11),
                dst: dummy_addr(12),
            },
        );
        flows.insert(
            fresh_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now),
                }),
                abort: dummy_handle(),
                src: dummy_addr(13),
                dst: dummy_addr(14),
            },
        );

        let closed = close_all_tcp_flows();
        assert_eq!(closed, 2, "watchdog closes every flow, idle or fresh");
        assert!(flows.is_empty(), "registry should be empty after close-all");

        flows.clear();
    }

    /// The idle-TTL sweeper must reap exactly the flows whose
    /// `last_active_ms` is at least `ttl_ms` in the past — the 2026-06-06
    /// after-hours wedge shape (upstream EOF'd, app never FINs, relay
    /// parked forever holding an accept permit) — and leave active flows
    /// untouched.
    #[tokio::test]
    async fn idle_sweep_reaps_only_expired_flows() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();

        let now = now_ms();
        let wedged_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
        let boundary_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
        let active_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);

        // Idle 10 min — well past a 5 min TTL.
        flows.insert(
            wedged_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now.saturating_sub(600_000)),
                }),
                abort: dummy_handle(),
                src: dummy_addr(21),
                dst: dummy_addr(22),
            },
        );
        // Idle exactly the TTL — the >= comparison must reap it.
        flows.insert(
            boundary_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now.saturating_sub(300_000)),
                }),
                abort: dummy_handle(),
                src: dummy_addr(23),
                dst: dummy_addr(24),
            },
        );
        // Active 1 s ago — must survive.
        flows.insert(
            active_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now.saturating_sub(1_000)),
                }),
                abort: dummy_handle(),
                src: dummy_addr(25),
                dst: dummy_addr(26),
            },
        );

        let reaped = sweep_idle_tcp_flows(300_000, now);
        assert_eq!(reaped, 2, "wedged + boundary flows reaped");
        assert!(flows.get(&wedged_id).is_none(), "wedged flow removed");
        assert!(flows.get(&boundary_id).is_none(), "boundary flow removed");
        assert!(flows.get(&active_id).is_some(), "active flow retained");

        flows.clear();
    }

    /// A sweep against an empty registry — and one where everything is
    /// fresh — must be a no-op.
    #[tokio::test]
    async fn idle_sweep_no_op_when_nothing_expired() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();

        assert_eq!(sweep_idle_tcp_flows(300_000, now_ms()), 0);

        let now = now_ms();
        let fresh_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
        flows.insert(
            fresh_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(now),
                }),
                abort: dummy_handle(),
                src: dummy_addr(27),
                dst: dummy_addr(28),
            },
        );
        assert_eq!(sweep_idle_tcp_flows(300_000, now), 0);
        assert!(flows.get(&fresh_id).is_some(), "fresh flow retained");

        flows.clear();
    }

    #[test]
    fn tcp_idle_ttl_setter_roundtrip() {
        let prev = tcp_idle_ttl_ms();
        assert!(set_tcp_idle_ttl_ms(0), "0 (disabled) is accepted");
        assert_eq!(tcp_idle_ttl_ms(), 0);
        assert!(set_tcp_idle_ttl_ms(42_000));
        assert_eq!(tcp_idle_ttl_ms(), 42_000);
        set_tcp_idle_ttl_ms(prev);
    }

    /// Tier 3 regression harness — see
    /// `docs/INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md`.
    ///
    /// Models the failure mode that operators reported as 断流: the
    /// upstream relay never starts (e.g. `DirectAdapter::dial_tcp`'s
    /// underlying `TcpStream::connect` is hung on a TEST-NET-1
    /// black-hole / iOS routing-cache transient), so
    /// `IdleTracking::touch` never runs and `FlowState.last_active_ms`
    /// stays frozen at its accept-time value. The watchdog must reap
    /// the flow within the configured `dial_deadline_ms` budget rather
    /// than waiting on cap-pressure eviction.
    #[tokio::test(start_paused = true)]
    async fn dial_watchdog_fires_when_relay_never_starts() {
        let now = now_ms();
        let state = Arc::new(FlowState {
            last_active_ms: AtomicU64::new(now),
        });

        let started = tokio::time::Instant::now();
        // Run with a 750 ms deadline (chosen above the 500 ms tick floor
        // so we hit exactly one tick before the deadline check) and
        // assert it resolves within a generous bound.
        let outer = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            run_dial_watchdog(state.clone(), now, 750),
        )
        .await;

        assert!(
            outer.is_ok(),
            "watchdog did not resolve within outer 3 s guard — regression"
        );
        let elapsed = started.elapsed();
        // Sub-1500 ms upper bound: the watchdog should fire after at most
        // ⌈750 / 500⌉ = 2 sleep ticks (1000 ms) plus the final re-check.
        assert!(
            elapsed < std::time::Duration::from_millis(1_500),
            "watchdog took {:?}, expected <1.5 s with a 750 ms deadline",
            elapsed
        );
        // The watchdog must not mutate `last_active_ms` — that's the
        // relay's job. Pin the contract so a future refactor can't
        // accidentally trample the field and mask a dial-hang regression.
        assert_eq!(state.last_active_ms.load(Ordering::Relaxed), now);
    }

    /// Mirror of the above for the "dial succeeded normally" case: the
    /// relay advances `last_active_ms` before the deadline expires, and
    /// the watchdog must park forever (i.e. not return) so the relay
    /// future owns the rest of the flow's lifetime. Drives the same
    /// `select!`-arm semantics as `dispatch_tcp` without standing up
    /// the netstack.
    #[tokio::test(start_paused = true)]
    async fn dial_watchdog_parks_when_relay_starts_in_time() {
        let now = now_ms();
        let state = Arc::new(FlowState {
            last_active_ms: AtomicU64::new(now),
        });

        // Bump `last_active_ms` after 200 ms — simulates the first
        // `IdleTracking::touch()` once the relay reads the app's first
        // payload. The watchdog should observe the advance on its first
        // 500 ms tick and park.
        let state_for_bump = state.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            state_for_bump
                .last_active_ms
                .store(now + 1, Ordering::Relaxed);
        });

        // 750 ms deadline; outer 2 s guard. If the watchdog mistakenly
        // returns despite the bump, the outer timeout doesn't fire and
        // `outer.is_err()` fails.
        let outer = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            run_dial_watchdog(state, now, 750),
        )
        .await;
        assert!(
            outer.is_err(),
            "watchdog returned despite the relay starting before the deadline — regression",
        );
    }

    /// `dial_deadline_ms == 0` is the documented opt-out: the watchdog
    /// must never fire, even if the relay never starts. Falls back to
    /// cap-pressure eviction as the only line of defence.
    #[tokio::test(start_paused = true)]
    async fn dial_watchdog_zero_deadline_opts_out() {
        let now = now_ms();
        let state = Arc::new(FlowState {
            last_active_ms: AtomicU64::new(now),
        });

        // 5 s outer guard with a 0 deadline: the watchdog should never
        // resolve in that window.
        let outer = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_dial_watchdog(state, now, 0),
        )
        .await;
        assert!(
            outer.is_err(),
            "0-ms deadline must opt out of the watchdog (parked forever)",
        );
    }

    #[test]
    fn dial_deadline_ms_roundtrip_and_zero_disables() {
        let prev = dial_deadline_ms();
        // Default initial value matches the documented threshold.
        // (Other tests don't touch this knob, so the first read sees it.)
        assert!(set_dial_deadline_ms(7_500));
        assert_eq!(dial_deadline_ms(), 7_500);
        assert!(set_dial_deadline_ms(0));
        assert_eq!(dial_deadline_ms(), 0, "0 must be accepted to opt out");
        // Restore so other parallel tests that may sample the knob see the
        // configured default.
        set_dial_deadline_ms(prev);
    }

    #[test]
    fn udp_first_reply_deadline_ms_roundtrip_and_zero_disables() {
        let prev = udp_first_reply_deadline_ms();
        assert!(set_udp_first_reply_deadline_ms(4_200));
        assert_eq!(udp_first_reply_deadline_ms(), 4_200);
        assert!(set_udp_first_reply_deadline_ms(0));
        assert_eq!(
            udp_first_reply_deadline_ms(),
            0,
            "0 must be accepted to opt out"
        );
        set_udp_first_reply_deadline_ms(prev);
    }

    /// Regression test for the 2026-06-07 stop()→start() clobber race: the
    /// old run task's deferred cleanup used to clear `ingress_slot` and
    /// lower `TUN2SOCKS_RUNNING` unconditionally — stealing them from the
    /// instance started right after. With the generation guard, a rapid
    /// stop/start cycle must leave the NEW instance fully wired.
    ///
    /// Builds two real lwip netstacks back-to-back (sequentially, as
    /// production does on every sleep/wake) — also exercising the fork's
    /// timeout-task abort + OUTPUT_CB_PTR self-check on teardown.
    #[test]
    fn rapid_stop_start_keeps_new_instance_wired() {
        let _guard = lifecycle_test_guard();

        unsafe extern "C" fn noop_write(
            _ctx: *mut std::os::raw::c_void,
            _data: *const u8,
            _len: usize,
        ) {
        }

        start(std::ptr::null_mut(), noop_write).expect("first start");
        stop();
        start(std::ptr::null_mut(), noop_write).expect("second start");

        // The first instance's deferred teardown runs within ~3s (the
        // second instance awaits it before building its stack). The
        // invariants must hold THROUGHOUT that window — the old bug only
        // manifested when the stale cleanup finally ran.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(4);
        while std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(100));
            assert!(
                TUN2SOCKS_RUNNING.load(Ordering::SeqCst),
                "old instance's teardown lowered TUN2SOCKS_RUNNING for the live instance"
            );
            assert!(
                ingress_slot().lock().is_some(),
                "old instance's teardown stole the live instance's ingress sender"
            );
        }
        assert_eq!(
            ingest(&[0u8; 20]),
            0,
            "live instance must still accept packets after the old teardown"
        );

        stop_blocking();
    }

    /// `stop_blocking()` must JOIN the run task before returning — unlike the
    /// fire-and-forget `stop()`. The egress write callback can only fire from
    /// inside the run task, so a drained `run_handle_slot` on return is the
    /// invariant that lets Swift's terminal `stop` `CFBridgingRelease` the
    /// writer ctx without a use-after-free. Builds a real lwip netstack.
    #[test]
    fn stop_blocking_joins_run_task_synchronously() {
        let _guard = lifecycle_test_guard();

        unsafe extern "C" fn noop_write(
            _ctx: *mut std::os::raw::c_void,
            _data: *const u8,
            _len: usize,
        ) {
        }

        start(std::ptr::null_mut(), noop_write).expect("start");
        assert!(
            run_handle_slot().lock().is_some(),
            "start must publish the run handle"
        );

        stop_blocking();

        // Synchronous teardown: the handle is taken and joined before return,
        // so the slot is empty and the run task (incl. its egress callback
        // loop) is guaranteed gone — the ctx is now safe to free.
        assert!(
            run_handle_slot().lock().is_none(),
            "stop_blocking must take and join the run handle before returning"
        );
        assert!(
            !TUN2SOCKS_RUNNING.load(Ordering::SeqCst),
            "stop_blocking must leave the tunnel not-running"
        );
        assert_eq!(
            ingest(&[0u8; 20]),
            -1,
            "ingress must be closed after stop_blocking"
        );

        // Idempotent: a second call with nothing to join is a no-op.
        stop_blocking();
    }
}
