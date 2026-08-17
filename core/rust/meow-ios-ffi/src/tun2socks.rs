//! tun2socks using netstack-smoltcp: Swift pushes raw IP packets in via
//! [`ingest`], netstack terminates TCP and UDP sessions in a userspace
//! smoltcp stack, and each flow dispatches through the local mixed / DNS
//! listeners owned by the embedded engine.
//!
//! Egress packets (netstack output) are handed back to Swift via a C
//! callback registered in [`start`]. No file descriptors cross the FFI.
//!
//! DNS: A (1), TXT (16), MX (15), PTR (12), and other non-blocked queries are
//! sent as raw UDP packets to the local meow-dns listener. A gets fake-IP
//! synthesis there; generic qtypes get meow-dns's upstream-forward behavior.
//! AAAA (28) queries are answered NOERROR-empty by the FFI itself when IPv6 is
//! disabled in app settings (the default) — the fake-IP pool is v4-only, so
//! stripping AAAA forces every client onto it instead of leaking (or
//! black-holing) connections over v6. When IPv6 is enabled, AAAA queries are
//! forwarded to meow-dns like A queries — with a v4-only fake-IP pool the
//! resolver itself suppresses AAAA for fake-IP'd domains, so clients still land
//! on the v4 fake path; the Swift TUN advertises an IPv6 address + default
//! route so v6-literal destinations enter the netstack. When "block HTTP/3" is
//! enabled, HTTPS/SVCB (65/64) queries also get NOERROR-empty so clients cannot
//! discover QUIC hints.
//!
//! NEDNSSettings advertises a TUN-subnet address as the system resolver, so
//! every UDP DNS query arrives as an in-TUN IP packet. netstack turns that into
//! a UDP payload, the FFI branches on qtype, and non-blocked queries go to the
//! local DNS listener with the reply injected back through netstack. The
//! resolver owns fake-IP synthesis, reverse mapping, hosts / NXDOMAIN
//! semantics, and TTL handling; the FFI owns only the qtype peek plus the
//! blocked-query short-circuit.
//!
//! TCP/UDP destination IPs come back as fake-IPs from meow's resolver pool.
//! `dispatch_tcp` and `dispatch_udp` pass the literal destination to the
//! mixed listener via SOCKS5; meow's normal inbound path reverses fake-IPs back
//! to the original qname before rule matching.
//!
//! UDP ASSOCIATE is one control TCP per **source socket**, not per 5-tuple.
//! SOCKS5 UDP already multiplexes destinations in the per-datagram header, so
//! a P2P client that fans one local port out to hundreds of peers (Xunlei /
//! Thunder on `:12345`, BitTorrent DHT, …) must not open hundreds of mixed-
//! listener connections. Each ASSOCIATE holds a mixed-listener slot, and that
//! listener is capped at 256 — a swarm saturates it and starves real TCP
//! (HTTPS never even completes `connect(127.0.0.1:mixed)`). Known Thunder
//! swarm ports are dropped before ASSOCIATE; everything else shares the
//! per-source session.

use crate::logging;
use futures::{SinkExt, StreamExt};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::raw::c_void;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::{mpsc, oneshot, watch, Notify, OwnedSemaphorePermit, Semaphore};
use tokio_util::task::TaskTracker;
use tracing::{info, trace, warn};

type UdpMsg = (Vec<u8>, SocketAddr, SocketAddr);
type AnyIpPktFrame = Vec<u8>;
type NetstackTcpStream = lwip::TcpStream;
/// One SOCKS5 UDP ASSOCIATE per app source socket. Destinations are
/// multiplexed in the SOCKS5 UDP header — see the module-level note.
type UdpSessionKey = SocketAddr;

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
// generation. Without the guard, a rapid stop()→start() let the OLD task's
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

// TCP accept-side cap removed: every smoltcp-accepted flow spawns its
// `dispatch_tcp` task immediately, with no in-flight semaphore. The cap was
// historically the dominant lever on peak NE RSS under a connection burst
// (see docs/INVESTIGATION-2026-05-16-stress-rss-netstack-smoltcp.md), so
// without it a burst is bounded only by upstream/relay backpressure and the
// 30 s idle sweeper — watch RSS against the ~50 MB NE jetsam ceiling.

// Hung-dial bounding lives in the engine now, not here. The old per-flow
// "dial deadline" watchdog (`DIAL_DEADLINE_MS` / `run_dial_watchdog`,
// removed) tried to detect a hung `DirectAdapter::dial_tcp` (see
// docs/INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md) from relay
// progress — but since the meow-listener refactor the SOCKS5 CONNECT
// reply is eager and `dispatch_tcp` bumped `last_active_ms` before the
// watchdog started, so it parked immediately and could never fire. The
// signal was unfixable at this layer anyway: "no relay progress yet" is
// indistinguishable from a legitimate plaintext long-poll waiting on its
// first downstream byte. The bound now sits where the hang actually is:
// `prepare_ios_config` (engine.rs) injects `tcp-connect-timeout: 10`,
// which meow-config wires into `DirectAdapter::with_connect_timeout` —
// established flows are untouched by construction, and a hung connect
// errors out of `dial_tcp`, closing the loopback leg so the app sees RST.

// First-payload gate on the TCP dial. lwIP completes the local 3-way
// handshake on its own (SYN in → SYN-ACK out), so *every* SYN that enters
// the TUN used to produce a mixed-listener connect + SOCKS5 CONNECT — a
// real meow connection through the rule engine — even when the app never
// sent a byte. Bare probes are common on iOS: port scans, Safari
// preconnect races, happy-eyeballs losers cancelled right after the
// handshake, reachability checks. Each one showed up as a phantom entry in
// the Connections UI and dialed a real upstream.
//
// `dispatch_tcp` therefore waits for the app's first payload bytes before
// creating any internal connection. A flow that EOFs/RSTs before sending
// data is dropped without meow ever seeing it. The wait is bounded: if the
// budget elapses with the flow still open, we dial anyway with no initial
// payload, because server-speaks-first protocols (SMTP / IMAP / POP3
// STARTTLS, FTP control) send nothing until the upstream banner arrives —
// an unbounded wait would deadlock them against the un-dialed upstream.
//
// 1 s default: probes and cancelled racers close within an RTT or two, so
// they are reliably absorbed, while the worst case for a genuine
// server-first flow is a one-second banner delay on rare, latency-tolerant
// protocols. Tunable at runtime via [`set_tcp_first_payload_wait_ms`] /
// `meow_tun_set_tcp_first_payload_wait_ms`; 0 restores the legacy
// dial-on-accept behaviour.
const TCP_FIRST_PAYLOAD_WAIT_MS_DEFAULT: u64 = 1_000;
static TCP_FIRST_PAYLOAD_WAIT_MS: AtomicU64 = AtomicU64::new(TCP_FIRST_PAYLOAD_WAIT_MS_DEFAULT);

/// Set the first-payload wait budget, in milliseconds. `0` disables the
/// gate (legacy behaviour: dial the mixed listener as soon as lwIP
/// accepts, even for flows that never send data). Returns true
/// unconditionally.
pub fn set_tcp_first_payload_wait_ms(ms: u64) -> bool {
    TCP_FIRST_PAYLOAD_WAIT_MS.store(ms, Ordering::Relaxed);
    true
}

/// Read the currently-configured first-payload wait budget, in
/// milliseconds. `0` means the gate is disabled.
pub fn tcp_first_payload_wait_ms() -> u64 {
    TCP_FIRST_PAYLOAD_WAIT_MS.load(Ordering::Relaxed)
}

// Per-UDP-session first-reply deadline. The UDP counterpart of the
// engine-side `tcp-connect-timeout` bound (see the note above the
// first-payload gate). UDP doesn't connect, so there's no
// `TcpStream::connect` hang to bound — but iOS auto-bypass can silently
// drop the outbound sendto when the kernel's scoped-routing cache is
// stale, in which case the upstream never sees the datagram and the
// reply reader sits forever on `session.conn.read_packet`. With this
// deadline, a session that produces zero replies within the budget is
// evicted from `nat_table` + `reply_readers`, so the next app datagram
// dispatches a fresh socket against (hopefully) a refreshed iOS route.
//
// 10 s default to match the engine's TCP connect bound. The cost for legit
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

// "Block HTTP/3 (QUIC)" toggle. Default OFF — current behaviour is preserved
// unless Swift flips it. When ON the tunnel cuts HTTP/3 off at two layers that
// reinforce each other:
//
//   1. UDP egress to dst:443 is dropped (QUIC's transport), killing any QUIC
//      handshake that still attempts a connection.
//   2. SVCB (64) / HTTPS (65) DNS queries are answered NOERROR-empty by the
//      intercept itself instead of being forwarded to meow-dns, so the client
//      never learns the HTTP/3 `alpn`/SvcParams and falls back to A / fake-IPv4
//      over TCP.
//
// Both prongs are wired to this single flag. Stored Relaxed — the toggle has no
// ordering relationship with other state; a stale read for one datagram is
// harmless.
static BLOCK_HTTP3: AtomicBool = AtomicBool::new(false);

/// Throttle slot for the QUIC/HTTP3 UDP-drop log (dst:443 dropped while the
/// block-HTTP3 toggle is on). Throttled via `warn_capped` to once per second so
/// a QUIC-heavy app doesn't flood the on-device log.
static BLOCK_HTTP3_DROP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

/// Enable or disable the "block HTTP/3 (QUIC)" behaviour. Default OFF. Returns
/// true unconditionally.
pub fn set_block_http3(on: bool) {
    BLOCK_HTTP3.store(on, Ordering::Relaxed);
}

/// Read whether the "block HTTP/3 (QUIC)" behaviour is currently enabled.
pub fn block_http3() -> bool {
    BLOCK_HTTP3.load(Ordering::Relaxed)
}

/// Whether IPv6 is enabled in app settings. Default OFF — the tunnel is
/// IPv4-only unless the user opts in. When OFF, AAAA (qtype 28) queries are
/// answered NOERROR-empty locally so clients fall back to the IPv4 path. When
/// ON, AAAA queries are forwarded to the meow-dns listener like A queries (the
/// resolver returns real upstream IPv6 addresses), and the Swift TUN is
/// configured with an IPv6 address + default route so those connections enter
/// the netstack. Stored Relaxed — a stale read for one datagram is harmless.
static IPV6_ENABLED: AtomicBool = AtomicBool::new(false);

/// Enable or disable IPv6. Default OFF. See [`IPV6_ENABLED`].
pub fn set_ipv6_enabled(on: bool) {
    IPV6_ENABLED.store(on, Ordering::Relaxed);
}

/// Read whether IPv6 is currently enabled.
pub fn ipv6_enabled() -> bool {
    IPV6_ENABLED.load(Ordering::Relaxed)
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
// `udp_sem` permit acquired when a **new source socket** opens an ASSOCIATE
// is moved into the per-source reply-reader task (see
// `spawn_socks5_udp_reply_reader`) and held until that task exits, so the
// permit population equals the live ASSOCIATE population. Subsequent
// datagrams from a source that already has a session take no permit —
// destinations are multiplexed on that one control TCP. 512 live
// ASSOCIATEs * (session + 4 KiB reader buffer) fits the ~50 MB NE jetsam
// budget; once full, new *sources* are dropped (UDP is lossy) rather than
// evicting working ones.
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

// Thunder / Xunlei swarm UDP ports. These never complete a SOCKS5 UDP
// first-reply through the mixed listener (peers don't answer the relay)
// but each 5-tuple used to open its own ASSOCIATE and pin a mixed slot
// for 10 s. Dropped before ASSOCIATE — Xunlei TCP control (api-pan,
// sandai.net over TCP) is unaffected. 8000 is deliberately omitted:
// too many legitimate services share it.
const P2P_UDP_DROP_PORTS: &[u16] = &[12_345, 12_346, 3506, 4322];
static P2P_UDP_DROP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

/// Local mixed-listener connect + SOCKS5 UDP ASSOCIATE handshake bound.
/// The OS `connect()` timeout is ~75 s (error 60); when the mixed listener
/// is queued/saturated that hang held a live-session permit and blocked
/// every other UDP source. 3 s is well above a healthy loopback handshake
/// and short enough that a P2P retry does not pin the cap.
const UDP_ASSOCIATE_DIAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

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
/// `dispatch_tcp` future, which closes both halves of the relay — the netstack
/// stream side and the SOCKS5 loopback connection into meow-listener.
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
) -> &'static Mutex<Option<std::sync::Weak<Mutex<HashMap<UdpSessionKey, Arc<Socks5UdpSession>>>>>> {
    static S: OnceLock<
        Mutex<Option<std::sync::Weak<Mutex<HashMap<UdpSessionKey, Arc<Socks5UdpSession>>>>>>,
    > = OnceLock::new();
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

    let rt = crate::get_tun2socks_runtime();
    let handle = rt.spawn(async move {
        if let Some(mut prev) = prev {
            // `stop()` is fire-and-forget: the previous run task may still
            // be draining its channel or running its teardown. lwip's
            // global state (OUTPUT_CB_PTR, netif hooks, pcb lists) assumes
            // exactly one live NetStack, so wait for the old instance to
            // finish before building a new one. Packets that arrive meanwhile
            // buffer (then drop) in the ingress channel, which beats
            // corrupting the stack. The wait is deliberately unbounded —
            // overlapping stacks is the worse failure — but logged every 5 s
            // so a wedged predecessor is visible in the engine log instead of
            // presenting as a silent packet blackout.
            let mut waited_s = 0u64;
            loop {
                match tokio::time::timeout(std::time::Duration::from_secs(5), &mut prev).await {
                    Ok(Ok(())) => break,
                    Ok(Err(e)) => {
                        logging::bridge_log(&format!(
                            "tun2socks: previous instance stopped with join error: {e}"
                        ));
                        break;
                    }
                    Err(_) => {
                        waited_s += 5;
                        logging::bridge_log(&format!(
                            "tun2socks: gen {my_gen} still waiting for previous instance teardown ({waited_s}s)"
                        ));
                    }
                }
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
/// Non-terminal callers can use [`stop`] only if they retain the ctx until a
/// later `start` or `stop_blocking`, whose `start`/join path awaits the
/// previous teardown via `run_handle_slot`.
///
/// MUST be called from a NON-runtime thread (the Swift control queue): it
/// `block_on`s the tun2socks runtime. Bounded by `JOIN_TIMEOUT` so a
/// pathological teardown hang can't freeze iOS's `stopTunnel` grace window;
/// if the bound trips we log and return anyway (a hung teardown is a separate
/// failure, and freezing shutdown is worse than a vanishingly-rare late
/// callback) — but the un-joined handle is restored into `run_handle_slot`
/// so a subsequent `start()` still serializes against the old generation
/// instead of overlapping its lwip teardown. Idempotent.
pub fn stop_blocking() {
    stop();
    let Some(mut handle) = run_handle_slot().lock().take() else {
        return;
    };
    const JOIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
    let joined = crate::get_tun2socks_runtime().block_on(async {
        match tokio::time::timeout(JOIN_TIMEOUT, &mut handle).await {
            Ok(Ok(())) => true,
            Ok(Err(e)) => {
                logging::bridge_log(&format!("tun2socks: stop_blocking join error: {e}"));
                true
            }
            Err(_) => {
                warn!(
                    "tun2socks: stop_blocking timed out after {:?}; run task still draining, releasing ctx anyway",
                    JOIN_TIMEOUT
                );
                false
            }
        }
    });
    if !joined {
        // The old run task outlived the join bound. Put its handle BACK so the
        // next `start()` serializes against the still-draining generation.
        // Dropping the handle here (the old behavior) detached the task: the
        // next `start()` then found no predecessor and built a fresh lwip
        // NetStack overlapping the old instance's teardown — the exact
        // two-live-stacks overlap `run_handle_slot` exists to prevent, and the
        // post-wake-restart window where teardown is slowest is precisely when
        // the 5 s bound trips. Only restore into an empty slot: a concurrent
        // `start()` (nothing serializes FFI callers) may already own it.
        let mut slot = run_handle_slot().lock();
        if slot.is_none() {
            *slot = Some(handle);
        }
    }
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
// Data-path health probe
//
// An end-to-end liveness check for the packet path: build a synthetic in-TUN
// DNS query (IPv4/UDP, dst port 53), push it through the SAME pipeline a real
// query from mDNSResponder takes — ingress channel → stack driver → lwip →
// UDP accept → dispatch_dns_udp → meow-dns listener → reply writer → lwip
// egress — and wait for the reply frame to come back out. A reply proves every
// stage is live; silence within the deadline means the path is wedged (or the
// engine is down), which is exactly the condition the wake-path restart
// exists to clear. In fake-IP mode the answer is synthesised locally, so the
// probe needs no upstream network and is safe to run while the physical
// interface is still reassociating after a wake.
// ---------------------------------------------------------------------------

/// Fixed client port for probe queries. Replies are matched on (dst port,
/// DNS ID) while a probe is armed; a stray real flow on this port would need
/// a colliding 16-bit ID during the probe window to be swallowed, and the
/// client would simply retry that one reply.
const PROBE_SRC_PORT: u16 = 53535;

/// Probe qname. Any name works — fake-IP synthesises an answer for every
/// non-filtered name — but a reserved-TLD name keeps the probe out of real
/// caches if the resolver is ever switched to redir-host mode (where this
/// query goes to the configured upstreams and the probe additionally checks
/// upstream reachability).
const PROBE_QNAME: &str = "probe.meow-ios.internal";

/// Interval between probe re-sends while waiting for a reply. Ingest is
/// drop-on-full, so a probe frame can be lost to a saturated ingress queue
/// (post-wake replay burst) or to the DNS burst cap; re-sending rides that
/// out instead of misreporting a busy-but-live path as wedged.
const PROBE_RESEND_INTERVAL: std::time::Duration = std::time::Duration::from_millis(500);

static PROBE_ARMED: AtomicBool = AtomicBool::new(false);
static PROBE_ID_SEQ: AtomicU64 = AtomicU64::new(1);

struct ProbeWatch {
    dns_id: u16,
    tx: oneshot::Sender<()>,
}

fn probe_watch_slot() -> &'static Mutex<Option<ProbeWatch>> {
    static S: OnceLock<Mutex<Option<ProbeWatch>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// Minimal DNS query payload for the probe: header (RD set) + one A/IN
/// question for [`PROBE_QNAME`]. No EDNS, no compression.
fn build_probe_dns_query(id: u16) -> Vec<u8> {
    let mut q = Vec::with_capacity(12 + PROBE_QNAME.len() + 6);
    q.extend_from_slice(&id.to_be_bytes());
    q.extend_from_slice(&[0x01, 0x00]); // standard query, RD
    q.extend_from_slice(&[0x00, 0x01]); // QDCOUNT = 1
    q.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // AN/NS/AR = 0
    for label in PROBE_QNAME.split('.') {
        q.push(label.len() as u8);
        q.extend_from_slice(label.as_bytes());
    }
    q.push(0);
    q.extend_from_slice(&[0x00, 0x01]); // QTYPE = A
    q.extend_from_slice(&[0x00, 0x01]); // QCLASS = IN
    q
}

/// Build the probe as a raw IPv4/UDP frame from `src_ip`:[`PROBE_SRC_PORT`]
/// to `dns_ip`:53 — the same shape as a real resolver query arriving on the
/// TUN. UDP checksum 0 (legal for IPv4 per RFC 768).
fn build_probe_packet(src_ip: std::net::Ipv4Addr, dns_ip: std::net::Ipv4Addr, id: u16) -> Vec<u8> {
    let payload = build_probe_dns_query(id);
    let total_len = (20 + 8 + payload.len()) as u16;
    let udp_len = (8 + payload.len()) as u16;

    let mut pkt = Vec::with_capacity(usize::from(total_len));
    pkt.push(0x45); // version=4, IHL=5
    pkt.push(0x00); // DSCP/ECN
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]); // identification
    pkt.extend_from_slice(&[0x40, 0x00]); // flags=DF, offset=0
    pkt.push(64); // TTL
    pkt.push(17); // protocol = UDP
    pkt.extend_from_slice(&[0, 0]); // header checksum placeholder
    pkt.extend_from_slice(&src_ip.octets());
    pkt.extend_from_slice(&dns_ip.octets());
    let cksum = ipv4_header_checksum(&pkt[0..20]);
    pkt[10..12].copy_from_slice(&cksum.to_be_bytes());

    pkt.extend_from_slice(&PROBE_SRC_PORT.to_be_bytes());
    pkt.extend_from_slice(&53u16.to_be_bytes());
    pkt.extend_from_slice(&udp_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]); // UDP checksum = 0
    pkt.extend_from_slice(&payload);
    pkt
}

/// Called by the egress task on every outbound frame while a probe is armed.
/// Returns `true` when `pkt` is the armed probe's DNS reply, in which case it
/// has been consumed (the waiter signalled) and must NOT be emitted to Swift
/// — the synthetic client doesn't exist, and handing iOS a datagram for its
/// own TUN address would be noise at best.
fn probe_reply_intercept(pkt: &[u8]) -> bool {
    if !PROBE_ARMED.load(Ordering::Relaxed) {
        return false;
    }
    let Some(udp) = parse_udp_packet(pkt) else {
        return false;
    };
    if udp.src_port != 53 || udp.dst_port != PROBE_SRC_PORT || udp.payload.len() < 2 {
        return false;
    }
    let reply_id = u16::from_be_bytes([udp.payload[0], udp.payload[1]]);
    let mut slot = probe_watch_slot().lock();
    let matched = slot.as_ref().is_some_and(|w| w.dns_id == reply_id);
    if !matched {
        return false;
    }
    let watch = slot.take();
    drop(slot);
    PROBE_ARMED.store(false, Ordering::Relaxed);
    if let Some(w) = watch {
        let _ = w.tx.send(());
    }
    true
}

/// Run one end-to-end data-path health probe. Returns:
///
/// * `0`  — a probe reply came back through the full pipeline: path is live.
/// * `-1` — tun2socks is not running.
/// * `-2` — no reply within `timeout_ms`: the data path (or the engine's DNS
///   listener) is not serving. The caller should restart the engine.
///
/// MUST be called from a NON-runtime thread (the Swift engine-control queue):
/// it `block_on`s the tun2socks runtime, like [`stop_blocking`]. Callers must
/// serialize probes; concurrent calls steal each other's watch slot and the
/// loser reports unhealthy.
pub fn health_probe(
    src_ip: std::net::Ipv4Addr,
    dns_ip: std::net::Ipv4Addr,
    timeout_ms: u64,
) -> i32 {
    if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }
    // u16 IDs wrap; skip 0 so a zeroed payload can't match a live watch.
    let id = loop {
        let raw = PROBE_ID_SEQ.fetch_add(1, Ordering::Relaxed) as u16;
        if raw != 0 {
            break raw;
        }
    };
    let (tx, mut rx) = oneshot::channel::<()>();
    *probe_watch_slot().lock() = Some(ProbeWatch { dns_id: id, tx });
    PROBE_ARMED.store(true, Ordering::SeqCst);

    let pkt = build_probe_packet(src_ip, dns_ip, id);
    let deadline = std::time::Duration::from_millis(timeout_ms.max(1));
    let healthy = crate::get_tun2socks_runtime().block_on(async {
        tokio::time::timeout(deadline, async {
            loop {
                let _ = ingest(&pkt);
                match tokio::time::timeout(PROBE_RESEND_INTERVAL, &mut rx).await {
                    Ok(Ok(())) => return true,
                    // Sender dropped without firing: watch slot was stolen or
                    // torn down — report unhealthy rather than spin.
                    Ok(Err(_)) => return false,
                    Err(_) => continue, // re-send and keep waiting
                }
            }
        })
        .await
        .unwrap_or(false)
    });

    PROBE_ARMED.store(false, Ordering::SeqCst);
    probe_watch_slot().lock().take();
    if healthy {
        0
    } else {
        -2
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

    // Flips once the single-owner lwip core task has finished its
    // deterministic teardown (every pcb closed, hooks cleared). Awaited at
    // the end of this generation so the next `start()`'s
    // wait-for-predecessor covers the core task too — lwIP's pcb lists are
    // process globals, and two live cores would corrupt them.
    let mut lwip_core_done = stack.core_done();

    let (udp_write, mut udp_read) = udp_socket.split();

    let (udp_reply_tx, mut udp_reply_rx) = mpsc::channel::<UdpMsg>(256);
    let udp_nat = UdpNat::new();
    // Publish a weak handle so `debug_counts()` (harness RSS monitor) can
    // sample this set's size without owning it.
    *reply_readers_slot().lock() = Some(Arc::downgrade(&udp_nat.sessions));

    let (stack_ingress_tx, mut stack_ingress_rx) = mpsc::channel::<AnyIpPktFrame>(256);
    let (egress_tx, mut egress_rx) = mpsc::channel::<Vec<u8>>(1024);

    let udp_sem = Arc::new(Semaphore::new(UDP_BURST_CAP));
    let dns_sem = Arc::new(Semaphore::new(DNS_BURST_CAP));
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

    let tcp_flow_tasks_for_accept = tcp_flow_tasks.clone();
    let engine_handle_for_tcp = crate::get_engine_runtime().handle().clone();
    let tcp_accept_handle = tokio::spawn(async move {
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
            let task = tcp_flow_tasks_for_accept.spawn_on(
                async move {
                    dispatch_tcp(stream, local_addr, remote_addr, state_for_task).await;
                    tcp_flows().remove(&flow_id);
                },
                &engine_handle_for_tcp,
            );
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
            // Health-probe replies are consumed here instead of being handed
            // to Swift: the probe's synthetic client doesn't exist on the
            // device side. Single atomic load when no probe is armed.
            if probe_reply_intercept(&pkt) {
                continue;
            }
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
    let udp_nat_accept = udp_nat.clone();
    let udp_sem_accept = udp_sem.clone();
    let dns_sem_accept = dns_sem.clone();
    let engine_handle_for_udp = crate::get_engine_runtime().handle().clone();
    let udp_accept_handle = tokio::spawn(async move {
        while let Some((payload, src, dst)) = udp_read.next().await {
            if dst.port() != 53 && should_drop_p2p_udp(dst) {
                warn_capped(
                    &P2P_UDP_DROP_LOG_LAST_MS,
                    "tun2socks: dropping P2P UDP swarm datagram (Thunder/Xunlei port)",
                );
                continue;
            }
            if dst.port() != 53 && block_http3() && dst.port() == 443 {
                warn_capped(
                    &BLOCK_HTTP3_DROP_LOG_LAST_MS,
                    "tun2socks: block-HTTP3 on, dropping outbound UDP/443 (QUIC)",
                );
                continue;
            }

            // DNS and first-ASSOCIATE-per-source take a permit. Datagrams
            // for a source that is already live or mid-open do not: they
            // multiplex on the existing control TCP and must not exhaust
            // UDP_BURST_CAP during a swarm burst or a 3 s ASSOCIATE dial.
            let permit = if dst.port() == 53 {
                match dns_sem_accept.clone().try_acquire_owned() {
                    Ok(p) => Some(p),
                    Err(_) => {
                        warn_capped(
                            &DNS_CAP_LOG_LAST_MS,
                            "tun2socks: DNS burst cap reached, dropping query",
                        );
                        continue;
                    }
                }
            } else {
                match udp_nat_accept.lookup(src) {
                    UdpLookup::Live(session) => {
                        let nat = udp_nat_accept.clone();
                        engine_handle_for_udp.spawn(async move {
                            dispatch_udp_on_session(session, payload, src, dst, Some(&nat)).await;
                        });
                        continue;
                    }
                    UdpLookup::Opening(wait) => {
                        let nat = udp_nat_accept.clone();
                        engine_handle_for_udp.spawn(async move {
                            dispatch_udp_wait(nat, wait, payload, src, dst).await;
                        });
                        continue;
                    }
                    UdpLookup::NeedOpen(wait) => match udp_sem_accept.clone().try_acquire_owned() {
                        Ok(p) => Some(p),
                        Err(_) => {
                            udp_nat_accept.fail_open(src, &wait);
                            warn_capped(
                                &UDP_CAP_LOG_LAST_MS,
                                "tun2socks: UDP live-session cap reached, dropping datagram",
                            );
                            continue;
                        }
                    },
                }
            };
            let reply_tx = udp_reply_tx_accept.clone();
            let nat = udp_nat_accept.clone();
            engine_handle_for_udp.spawn(async move {
                dispatch_udp(payload, src, dst, reply_tx, nat, permit).await;
            });
        }
    });

    while let Some(ip_data) = ingress_rx.recv().await {
        if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
            break;
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

    // Await cancellation of our forwarding tasks before this outer generation
    // finishes. Handle drops no longer touch lwIP state (the single-owner
    // core owns every C call), but joining after `abort()` still matters:
    // detached tasks would keep pumping channels — and holding lwip handles —
    // while the next generation spins up.
    abort_and_join("tcp accept", tcp_accept_handle).await;

    close_all_tcp_flows();
    tcp_flow_tasks.close();
    tcp_flow_tasks.wait().await;

    abort_and_join("udp writer", udp_writer_handle).await;
    abort_and_join("stack driver", stack_handle).await;
    abort_and_join("udp accept", udp_accept_handle).await;
    abort_and_join("egress", egress_handle).await;
    abort_and_join("tcp idle sweeper", tcp_idle_sweeper_handle).await;
    drop(udp_reply_tx);

    // Every lwip handle (stack, listener, udp halves, streams) is dropped by
    // now, which triggers the core task's teardown of every pcb. Wait for it
    // to finish so two cores never overlap on the process-global lwIP state;
    // a wedged core surfaces via `start()`'s "still waiting for previous
    // instance teardown" logging rather than as silent corruption.
    if lwip_core_done.wait_for(|done| *done).await.is_err() {
        logging::bridge_log("tun2socks: lwip core exited without done signal");
    }

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
    let Some(mixed_addr) = crate::engine::mixed_dial_addr() else {
        logging::bridge_log("tun2socks: mixed listener not running, dropping TCP flow");
        return;
    };

    let eof_state = state.clone();

    let local_eof = Arc::new(Notify::new());
    let mut local = IdleTracking {
        inner: stream,
        state,
        local_eof: local_eof.clone(),
        eof_fired: AtomicBool::new(false),
    };

    // First-payload gate (see TCP_FIRST_PAYLOAD_WAIT_MS docs above): no
    // internal meow connection exists yet at this point — a probe that
    // closes without sending data returns here having cost only an lwIP
    // pcb and this task.
    let first_payload = match await_first_payload(
        &mut local,
        TCP_FIRST_PAYLOAD_WAIT_MS.load(Ordering::Relaxed),
    )
    .await
    {
        FirstPayload::Payload(buf) => Some(buf),
        FirstPayload::DialWithout => None,
        FirstPayload::Closed => {
            trace!("tun2socks: {src} -> {dst} closed before first payload; skipping meow dial");
            return;
        }
    };

    let mut proxy = match TcpStream::connect(mixed_addr).await {
        Ok(s) => s,
        Err(e) => {
            warn!("tun2socks: connect mixed listener {mixed_addr} failed for {src} -> {dst}: {e}");
            return;
        }
    };
    if let Err(e) = socks5_connect(&mut proxy, dst).await {
        warn!("tun2socks: SOCKS5 CONNECT {src} -> {dst} failed: {e}");
        return;
    }
    if let Some(chunk) = first_payload {
        if let Err(e) = proxy.write_all(&chunk).await {
            warn!("tun2socks: forwarding first payload {src} -> {dst} failed: {e}");
            return;
        }
    }

    let relay = tokio::io::copy_bidirectional(&mut local, &mut proxy);
    tokio::pin!(relay);

    tokio::select! {
        biased;
        _ = &mut relay => {}
        _ = local_eof.notified() => {
            loop {
                let before = eof_state.last_active_ms.load(Ordering::Relaxed);
                match tokio::time::timeout(HALF_CLOSE_IDLE_GRACE, &mut relay).await {
                    Ok(_) => break,
                    Err(_) => {
                        if eof_state.last_active_ms.load(Ordering::Relaxed) == before {
                            break;
                        }
                    }
                }
            }
        }
    }
}

/// Outcome of the pre-dial first-payload wait. See
/// `TCP_FIRST_PAYLOAD_WAIT_MS` for the rationale.
enum FirstPayload {
    /// The app sent data; forward this chunk right after SOCKS5 CONNECT
    /// succeeds (the relay picks up anything beyond the first read).
    Payload(Vec<u8>),
    /// Dial without an initial payload: either the gate is disabled
    /// (`wait_ms == 0`) or the budget elapsed with the flow still open —
    /// the server-speaks-first fallback.
    DialWithout,
    /// The local endpoint EOF'd/RST'd before sending any payload (SYN
    /// probe, cancelled happy-eyeballs racer). No meow connection should
    /// be created.
    Closed,
}

/// Wait up to `wait_ms` for the first payload bytes from the local
/// netstack stream. Factored out of `dispatch_tcp` so unit tests can
/// drive it with an in-memory duplex stream — see the
/// `first_payload_*` tests at the bottom of this file.
async fn await_first_payload<R: AsyncRead + Unpin>(local: &mut R, wait_ms: u64) -> FirstPayload {
    if wait_ms == 0 {
        return FirstPayload::DialWithout;
    }
    // 4 KiB covers typical first client messages (HTTP request line +
    // headers, TLS ClientHello) in one read; anything larger simply
    // continues through the relay once it starts.
    let mut buf = vec![0u8; 4096];
    match tokio::time::timeout(
        std::time::Duration::from_millis(wait_ms),
        local.read(&mut buf),
    )
    .await
    {
        Ok(Ok(0)) | Ok(Err(_)) => FirstPayload::Closed,
        Ok(Ok(n)) => {
            buf.truncate(n);
            FirstPayload::Payload(buf)
        }
        Err(_) => FirstPayload::DialWithout,
    }
}

// ---------------------------------------------------------------------------
// SOCKS5 loopback helpers.
// ---------------------------------------------------------------------------

const SOCKS5_VERSION: u8 = 0x05;
const SOCKS5_NO_AUTH: u8 = 0x00;
const SOCKS5_CMD_CONNECT: u8 = 0x01;
const SOCKS5_CMD_UDP_ASSOCIATE: u8 = 0x03;
const SOCKS5_ATYP_IPV4: u8 = 0x01;
const SOCKS5_ATYP_DOMAIN: u8 = 0x03;
const SOCKS5_ATYP_IPV6: u8 = 0x04;

async fn socks5_negotiate(stream: &mut TcpStream) -> io::Result<()> {
    stream
        .write_all(&[SOCKS5_VERSION, 1, SOCKS5_NO_AUTH])
        .await?;
    let mut resp = [0u8; 2];
    stream.read_exact(&mut resp).await?;
    if resp != [SOCKS5_VERSION, SOCKS5_NO_AUTH] {
        return Err(io::Error::other(format!(
            "SOCKS5 no-auth rejected: {resp:?}"
        )));
    }
    Ok(())
}

fn encode_socks5_addr(out: &mut Vec<u8>, addr: SocketAddr) {
    match addr.ip() {
        IpAddr::V4(ip) => {
            out.push(SOCKS5_ATYP_IPV4);
            out.extend_from_slice(&ip.octets());
        }
        IpAddr::V6(ip) => {
            out.push(SOCKS5_ATYP_IPV6);
            out.extend_from_slice(&ip.octets());
        }
    }
    out.extend_from_slice(&addr.port().to_be_bytes());
}

async fn read_socks5_reply_addr(stream: &mut TcpStream) -> io::Result<SocketAddr> {
    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != SOCKS5_VERSION || head[1] != 0 {
        return Err(io::Error::other(format!("SOCKS5 reply failure: {head:?}")));
    }
    let ip = match head[3] {
        SOCKS5_ATYP_IPV4 => {
            let mut octets = [0u8; 4];
            stream.read_exact(&mut octets).await?;
            IpAddr::from(octets)
        }
        SOCKS5_ATYP_IPV6 => {
            let mut octets = [0u8; 16];
            stream.read_exact(&mut octets).await?;
            IpAddr::from(octets)
        }
        SOCKS5_ATYP_DOMAIN => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut name_buf = vec![0u8; len[0] as usize];
            stream.read_exact(&mut name_buf).await?;
            IpAddr::from([0, 0, 0, 0])
        }
        atyp => return Err(io::Error::other(format!("SOCKS5 reply atyp {atyp}"))),
    };
    let mut port = [0u8; 2];
    stream.read_exact(&mut port).await?;
    Ok(SocketAddr::new(ip, u16::from_be_bytes(port)))
}

async fn socks5_connect(stream: &mut TcpStream, dst: SocketAddr) -> io::Result<()> {
    socks5_negotiate(stream).await?;
    let mut req = vec![SOCKS5_VERSION, SOCKS5_CMD_CONNECT, 0];
    encode_socks5_addr(&mut req, dst);
    stream.write_all(&req).await?;
    let _ = read_socks5_reply_addr(stream).await?;
    Ok(())
}

/// Wraps an `AsyncRead + AsyncWrite` to bump `FlowState::last_active_ms` on
/// every poll that returned `Ready(Ok(_))`. The stamp covers both directions
/// because the relay drives this end's `poll_read` (bytes from the app) and
/// `poll_write` (bytes from the upstream peer) on the same wrapper.
/// Pending / would-block polls are intentionally not counted as activity.
///
/// Generic over the inner stream so the idle-tracking semantics stay local to
/// the netstack side while the other half of the relay is the SOCKS5 loopback
/// connection into meow-listener.
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

// ---------------------------------------------------------------------------
// UDP dispatch through DNS listener / SOCKS5 UDP ASSOCIATE.
// ---------------------------------------------------------------------------

/// Per-run UDP ASSOCIATE table. `sessions` is the live set (one entry per
/// app source socket). `opening` holds a `watch` sender so concurrent
/// datagrams from the same source wait for the in-flight ASSOCIATE instead
/// of each opening their own mixed-listener TCP.
#[derive(Clone)]
struct UdpNat {
    sessions: Arc<Mutex<HashMap<UdpSessionKey, Arc<Socks5UdpSession>>>>,
    opening: Arc<Mutex<HashMap<UdpSessionKey, watch::Sender<bool>>>>,
}

enum UdpLookup {
    Live(Arc<Socks5UdpSession>),
    Opening(watch::Receiver<bool>),
    NeedOpen(watch::Sender<bool>),
}

impl UdpNat {
    fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            opening: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn lookup(&self, src: SocketAddr) -> UdpLookup {
        if let Some(s) = self.sessions.lock().get(&src).cloned() {
            return UdpLookup::Live(s);
        }
        let mut opening = self.opening.lock();
        // Re-check under the opening lock so a just-published session is
        // not classified as NeedOpen.
        if let Some(s) = self.sessions.lock().get(&src).cloned() {
            return UdpLookup::Live(s);
        }
        if let Some(tx) = opening.get(&src) {
            UdpLookup::Opening(tx.subscribe())
        } else {
            let (tx, _rx) = watch::channel(false);
            opening.insert(src, tx.clone());
            UdpLookup::NeedOpen(tx)
        }
    }

    fn insert_live(&self, src: SocketAddr, session: Arc<Socks5UdpSession>) {
        self.sessions.lock().insert(src, session);
    }

    fn remove_if(&self, src: SocketAddr, session: &Arc<Socks5UdpSession>) {
        let mut g = self.sessions.lock();
        if g.get(&src).is_some_and(|s| Arc::ptr_eq(s, session)) {
            g.remove(&src);
        }
    }

    fn publish_open(&self, src: SocketAddr, tx: &watch::Sender<bool>) {
        self.opening.lock().remove(&src);
        let _ = tx.send(true);
    }

    fn fail_open(&self, src: SocketAddr, tx: &watch::Sender<bool>) {
        self.publish_open(src, tx);
    }

    fn fail_open_src(&self, src: SocketAddr) {
        if let Some(tx) = self.opening.lock().remove(&src) {
            let _ = tx.send(true);
        }
    }
}

fn should_drop_p2p_udp(dst: SocketAddr) -> bool {
    P2P_UDP_DROP_PORTS.contains(&dst.port())
}

async fn dispatch_udp(
    payload: Vec<u8>,
    src: SocketAddr,
    dst: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
    nat: UdpNat,
    permit: Option<OwnedSemaphorePermit>,
) {
    if dst.port() == 53 {
        let _permit = permit;
        dispatch_dns_udp(payload, src, dst, reply_tx).await;
        return;
    }

    if block_http3() && dst.port() == 443 {
        warn_capped(
            &BLOCK_HTTP3_DROP_LOG_LAST_MS,
            "tun2socks: block-HTTP3 on, dropping outbound UDP/443 (QUIC)",
        );
        nat.fail_open_src(src);
        return;
    }

    // Only NeedOpen reaches here with Some(permit). Live/Opening are
    // dispatched via the dedicated helpers so they never hold a cap slot.
    let Some(permit) = permit else {
        let existing = nat.sessions.lock().get(&src).cloned();
        if let Some(session) = existing {
            dispatch_udp_on_session(session, payload, src, dst, Some(&nat)).await;
        }
        return;
    };

    let Some(mixed_addr) = crate::engine::mixed_dial_addr() else {
        logging::bridge_log("tun2socks: mixed listener not running, dropping UDP datagram");
        nat.fail_open_src(src);
        return;
    };

    let session = match open_socks5_udp_session(mixed_addr).await {
        Ok(s) => s,
        Err(e) => {
            warn!("tun2socks: SOCKS5 UDP ASSOCIATE failed for {src} -> {dst}: {e}");
            nat.fail_open_src(src);
            return;
        }
    };

    nat.insert_live(src, session.clone());
    nat.fail_open_src(src);
    spawn_socks5_udp_reply_reader(src, session.clone(), src, reply_tx, nat.clone(), permit);
    dispatch_udp_on_session(session, payload, src, dst, Some(&nat)).await;
}

async fn dispatch_udp_wait(
    nat: UdpNat,
    mut wait: watch::Receiver<bool>,
    payload: Vec<u8>,
    src: SocketAddr,
    dst: SocketAddr,
) {
    if !*wait.borrow() {
        let _ = wait.changed().await;
    }
    let existing = nat.sessions.lock().get(&src).cloned();
    if let Some(session) = existing {
        dispatch_udp_on_session(session, payload, src, dst, Some(&nat)).await;
    }
}

async fn dispatch_udp_on_session(
    session: Arc<Socks5UdpSession>,
    payload: Vec<u8>,
    src: SocketAddr,
    dst: SocketAddr,
    nat: Option<&UdpNat>,
) {
    if let Err(e) = send_socks5_udp(&session, dst, &payload).await {
        warn!("tun2socks: SOCKS5 UDP send failed for {src} -> {dst}: {e}");
        if let Some(nat) = nat {
            nat.remove_if(src, &session);
        }
    }
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

struct Socks5UdpSession {
    udp: Arc<UdpSocket>,
    relay_addr: SocketAddr,
    control_abort: tokio::task::AbortHandle,
    last_activity_ms: AtomicU64,
}

impl Drop for Socks5UdpSession {
    fn drop(&mut self) {
        self.control_abort.abort();
    }
}

async fn open_socks5_udp_session(mixed_addr: SocketAddr) -> io::Result<Arc<Socks5UdpSession>> {
    let mut control =
        tokio::time::timeout(UDP_ASSOCIATE_DIAL_TIMEOUT, TcpStream::connect(mixed_addr))
            .await
            .map_err(|_| {
                io::Error::new(io::ErrorKind::TimedOut, "UDP ASSOCIATE connect timed out")
            })??;
    socks5_negotiate(&mut control).await?;
    control
        .write_all(&[
            SOCKS5_VERSION,
            SOCKS5_CMD_UDP_ASSOCIATE,
            0,
            SOCKS5_ATYP_IPV4,
            0,
            0,
            0,
            0,
            0,
            0,
        ])
        .await?;
    let relay_addr = read_socks5_reply_addr(&mut control).await?;
    let local_ip = match relay_addr.ip() {
        IpAddr::V4(_) => IpAddr::from([127, 0, 0, 1]),
        IpAddr::V6(_) => IpAddr::from([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
    };
    let udp = Arc::new(UdpSocket::bind(SocketAddr::new(local_ip, 0)).await?);
    let control_task = tokio::spawn(async move {
        let mut buf = [0u8; 16];
        loop {
            match control.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
        }
    });
    let control_abort = control_task.abort_handle();
    Ok(Arc::new(Socks5UdpSession {
        udp,
        relay_addr,
        control_abort,
        last_activity_ms: AtomicU64::new(now_ms()),
    }))
}

fn encode_socks5_udp_header(out: &mut Vec<u8>, addr: SocketAddr) {
    out.extend_from_slice(&[0, 0, 0]);
    encode_socks5_addr(out, addr);
}

/// Decode a SOCKS5 UDP request/reply header. Returns `(dst, payload_offset)`.
/// Fragmented datagrams (`FRAG != 0`) and domain ATYP are rejected: the
/// netstack can only inject an IP-sourced UDP packet back to the app.
fn decode_socks5_udp(buf: &[u8]) -> Option<(SocketAddr, usize)> {
    if buf.len() < 4 || buf[0] != 0 || buf[1] != 0 || buf[2] != 0 {
        return None;
    }
    let (ip, port_off) = match buf[3] {
        SOCKS5_ATYP_IPV4 => {
            if buf.len() < 10 {
                return None;
            }
            (IpAddr::from([buf[4], buf[5], buf[6], buf[7]]), 8usize)
        }
        SOCKS5_ATYP_IPV6 => {
            if buf.len() < 22 {
                return None;
            }
            let mut octets = [0u8; 16];
            octets.copy_from_slice(&buf[4..20]);
            (IpAddr::from(octets), 20usize)
        }
        _ => return None,
    };
    if buf.len() < port_off + 2 {
        return None;
    }
    let port = u16::from_be_bytes([buf[port_off], buf[port_off + 1]]);
    Some((SocketAddr::new(ip, port), port_off + 2))
}

async fn send_socks5_udp(
    session: &Socks5UdpSession,
    dst: SocketAddr,
    payload: &[u8],
) -> io::Result<()> {
    let mut packet = Vec::with_capacity(10 + payload.len());
    encode_socks5_udp_header(&mut packet, dst);
    packet.extend_from_slice(payload);
    session
        .udp
        .send_to(&packet, session.relay_addr)
        .await
        .map(|_| ())?;
    session.last_activity_ms.store(now_ms(), Ordering::Relaxed);
    Ok(())
}

fn spawn_socks5_udp_reply_reader(
    key: UdpSessionKey,
    session: Arc<Socks5UdpSession>,
    app_src: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
    nat: UdpNat,
    permit: OwnedSemaphorePermit,
) {
    crate::get_engine_runtime().spawn(async move {
        let _permit = permit;
        let mut buf = vec![0u8; 4 * 1024];
        let first_reply_deadline_ms = UDP_FIRST_REPLY_DEADLINE_MS.load(Ordering::Relaxed);
        let mut had_first_reply = false;
        'reader: loop {
            let read = if !had_first_reply && first_reply_deadline_ms > 0 {
                match tokio::time::timeout(
                    std::time::Duration::from_millis(first_reply_deadline_ms),
                    session.udp.recv_from(&mut buf),
                )
                .await
                {
                    Ok(res) => res,
                    Err(_) => {
                        warn!(
                            "UDP first-reply deadline exceeded for {key} after {first_reply_deadline_ms} ms; evicting session"
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
                        session.udp.recv_from(&mut buf),
                    )
                    .await
                    {
                        Ok(res) => break res,
                        Err(_) => {
                            let idle_ms = now_ms()
                                .saturating_sub(session.last_activity_ms.load(Ordering::Relaxed));
                            if idle_ms >= UDP_REPLY_IDLE_TTL.as_millis() as u64 {
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
                    session.last_activity_ms.store(now_ms(), Ordering::Relaxed);
                    // Shared ASSOCIATE: the reply may be from any dest the
                    // source has spoken to. Reconstruct the peer from the
                    // SOCKS5 UDP header so netstack emits the correct src.
                    let Some((remote, off)) = decode_socks5_udp(&buf[..n]) else {
                        continue;
                    };
                    if off > n {
                        continue;
                    }
                    let msg: UdpMsg = (buf[off..n].to_vec(), remote, app_src);
                    forward_udp_reply(&reply_tx, msg);
                }
                Err(e) => {
                    info!("UDP reply reader closing for {key}: {e}");
                    break 'reader;
                }
            }
        }
        nat.remove_if(key, &session);
    });
}

// ---------------------------------------------------------------------------
// DNS dispatch — block selected qtypes locally, otherwise forward the raw
// query to the local meow-dns listener and inject the reply back through
// netstack.
// ---------------------------------------------------------------------------

async fn dispatch_dns_udp(
    payload: Vec<u8>,
    src: SocketAddr,
    dst: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
) {
    let qtype = parse_dns_qtype(&payload);
    let response_payload = if (qtype == Some(28) && !ipv6_enabled())
        || (block_http3() && matches!(qtype, Some(64) | Some(65)))
    {
        match dns_empty_response(&payload) {
            Some(bytes) => bytes,
            None => return,
        }
    } else if let Some(dns_addr) = crate::engine::dns_dial_addr() {
        match query_dns_listener(&payload, dns_addr).await {
            Some(bytes) => bytes,
            None => {
                trace!("tun2socks: DNS listener timed out (qtype={:?})", qtype);
                return;
            }
        }
    } else {
        trace!(
            "tun2socks: DNS listener not running, dropping qtype={:?}",
            qtype
        );
        return;
    };
    forward_udp_reply(&reply_tx, (response_payload, dst, src));
}

async fn query_dns_listener(query: &[u8], dns_addr: SocketAddr) -> Option<Vec<u8>> {
    if query.len() < 2 {
        return None;
    }
    let query_id = u16::from_be_bytes([query[0], query[1]]);
    let bind_addr = match dns_addr {
        SocketAddr::V4(_) => SocketAddr::from(([127, 0, 0, 1], 0)),
        SocketAddr::V6(_) => {
            SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], 0))
        }
    };
    let socket = UdpSocket::bind(bind_addr).await.ok()?;
    socket.send_to(query, dns_addr).await.ok()?;
    let mut buf = [0u8; 4096];
    let recv = tokio::time::timeout(DNS_TASK_TIMEOUT, socket.recv_from(&mut buf)).await;
    let (n, _from) = recv.ok()?.ok()?;
    if n >= 2 && u16::from_be_bytes([buf[0], buf[1]]) == query_id {
        Some(buf[..n].to_vec())
    } else {
        None
    }
}

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
#[cfg(test)]
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
#[cfg(test)]
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
    use std::net::{Ipv4Addr, Ipv6Addr};
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

    #[test]
    fn decode_socks5_udp_roundtrip_ipv4() {
        let dst = SocketAddr::from((Ipv4Addr::new(183, 248, 6, 106), 12_345));
        let mut pkt = Vec::new();
        encode_socks5_udp_header(&mut pkt, dst);
        pkt.extend_from_slice(b"hi");
        let (got, off) = decode_socks5_udp(&pkt).expect("header decodes");
        assert_eq!(got, dst);
        assert_eq!(&pkt[off..], b"hi");
    }

    #[test]
    fn decode_socks5_udp_roundtrip_ipv6() {
        let dst = SocketAddr::from((Ipv6Addr::LOCALHOST, 443));
        let mut pkt = Vec::new();
        encode_socks5_udp_header(&mut pkt, dst);
        pkt.extend_from_slice(&[1, 2, 3]);
        let (got, off) = decode_socks5_udp(&pkt).expect("header decodes");
        assert_eq!(got, dst);
        assert_eq!(&pkt[off..], &[1, 2, 3]);
    }

    #[test]
    fn decode_socks5_udp_rejects_fragment_and_domain() {
        // FRAG != 0
        let mut frag = vec![0, 0, 1, SOCKS5_ATYP_IPV4, 1, 2, 3, 4, 0, 53];
        frag.extend_from_slice(b"x");
        assert!(decode_socks5_udp(&frag).is_none());

        // ATYP domain — cannot inject as an IP-sourced UDP packet
        let mut domain = vec![0, 0, 0, SOCKS5_ATYP_DOMAIN, 7];
        domain.extend_from_slice(b"foo.com");
        domain.extend_from_slice(&[0, 53, b'x']);
        assert!(decode_socks5_udp(&domain).is_none());
    }

    #[test]
    fn p2p_udp_drop_is_restricted_to_thunder_swarm_ports() {
        let ip = Ipv4Addr::new(183, 248, 6, 106);
        for port in [12_345, 12_346, 3506, 4322] {
            assert!(
                should_drop_p2p_udp(SocketAddr::from((ip, port))),
                "port {port} should drop"
            );
        }
        for port in [53, 443, 8000, 3478, 19_399] {
            assert!(
                !should_drop_p2p_udp(SocketAddr::from((ip, port))),
                "port {port} must not drop"
            );
        }
    }

    #[test]
    fn udp_nat_lookup_shares_one_open_per_source() {
        let nat = UdpNat::new();
        let src = SocketAddr::from((Ipv4Addr::new(172, 19, 0, 1), 64_479));
        match nat.lookup(src) {
            UdpLookup::NeedOpen(_) => {}
            UdpLookup::Live(_) => panic!("first lookup must NeedOpen, got Live"),
            UdpLookup::Opening(_) => panic!("first lookup must NeedOpen, got Opening"),
        }
        match nat.lookup(src) {
            UdpLookup::Opening(_) => {}
            UdpLookup::Live(_) => panic!("second lookup must Opening, got Live"),
            UdpLookup::NeedOpen(_) => panic!("second lookup must Opening, got NeedOpen"),
        }
        // A different source still gets its own ASSOCIATE.
        let other = SocketAddr::from((Ipv4Addr::new(172, 19, 0, 1), 64_480));
        match nat.lookup(other) {
            UdpLookup::NeedOpen(_) => {}
            UdpLookup::Live(_) => panic!("other src must NeedOpen, got Live"),
            UdpLookup::Opening(_) => panic!("other src must NeedOpen, got Opening"),
        }
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

    #[test]
    fn tcp_first_payload_wait_setter_roundtrip() {
        let prev = tcp_first_payload_wait_ms();
        assert!(set_tcp_first_payload_wait_ms(0), "0 (disabled) is accepted");
        assert_eq!(tcp_first_payload_wait_ms(), 0);
        assert!(set_tcp_first_payload_wait_ms(2_500));
        assert_eq!(tcp_first_payload_wait_ms(), 2_500);
        set_tcp_first_payload_wait_ms(prev);
    }

    /// App sends data promptly → the gate hands back exactly those bytes
    /// so `dispatch_tcp` can forward them after SOCKS5 CONNECT.
    #[tokio::test(start_paused = true)]
    async fn first_payload_returns_app_bytes() {
        let (mut app, mut tun) = tokio::io::duplex(4096);
        app.write_all(b"GET / HTTP/1.1\r\n").await.unwrap();
        match await_first_payload(&mut tun, 1_000).await {
            FirstPayload::Payload(buf) => assert_eq!(buf, b"GET / HTTP/1.1\r\n"),
            _ => panic!("expected Payload"),
        }
    }

    /// SYN-probe shape: local endpoint closes without ever sending a
    /// byte. The gate must report Closed so no meow connection is
    /// created.
    #[tokio::test(start_paused = true)]
    async fn first_payload_probe_close_skips_dial() {
        let (app, mut tun) = tokio::io::duplex(4096);
        drop(app);
        assert!(matches!(
            await_first_payload(&mut tun, 1_000).await,
            FirstPayload::Closed
        ));
    }

    /// Server-speaks-first fallback: the flow stays open but silent past
    /// the budget → dial anyway, with no initial payload.
    #[tokio::test(start_paused = true)]
    async fn first_payload_timeout_dials_without_payload() {
        let (_app, mut tun) = tokio::io::duplex(4096);
        assert!(matches!(
            await_first_payload(&mut tun, 1_000).await,
            FirstPayload::DialWithout
        ));
    }

    /// `0` opts out entirely: no read is attempted (pending app bytes are
    /// left for the relay) and the dial proceeds immediately — the legacy
    /// dial-on-accept pipeline.
    #[tokio::test(start_paused = true)]
    async fn first_payload_zero_budget_opts_out() {
        let (mut app, mut tun) = tokio::io::duplex(4096);
        app.write_all(b"hello").await.unwrap();
        assert!(matches!(
            await_first_payload(&mut tun, 0).await,
            FirstPayload::DialWithout
        ));
        // The pending bytes were not consumed by the disabled gate.
        let mut buf = [0u8; 5];
        tun.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"hello");
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
    /// Builds two real lwip netstacks back-to-back, also exercising the fork's
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

    /// Serializes tests that mutate the process-global probe state
    /// (`PROBE_ARMED`, `probe_watch_slot`).
    fn probe_test_guard() -> std::sync::MutexGuard<'static, ()> {
        static GUARD: StdMutex<()> = StdMutex::new(());
        GUARD.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn probe_packet_round_trips_as_dns_a_query() {
        let src = Ipv4Addr::new(172, 19, 0, 1);
        let dns = Ipv4Addr::new(172, 19, 0, 2);
        let pkt = build_probe_packet(src, dns, 0xBEEF);

        let udp = parse_udp_packet(&pkt).expect("probe packet must parse as IPv4/UDP");
        assert_eq!(udp.src_ip, u32::from(src));
        assert_eq!(udp.dst_ip, u32::from(dns));
        assert_eq!(udp.src_port, PROBE_SRC_PORT);
        assert_eq!(udp.dst_port, 53);
        assert_eq!(
            u16::from_be_bytes([udp.payload[0], udp.payload[1]]),
            0xBEEF,
            "DNS ID must round-trip"
        );
        assert_eq!(
            parse_dns_qtype(udp.payload),
            Some(1),
            "probe queries qtype A"
        );

        // Header checksum must validate (recomputing over the header with the
        // checksum field in place sums to zero → stored value was correct).
        let mut hdr = pkt[0..20].to_vec();
        hdr[10] = 0;
        hdr[11] = 0;
        assert_eq!(
            ipv4_header_checksum(&hdr).to_be_bytes(),
            [pkt[10], pkt[11]],
            "IPv4 header checksum must be valid"
        );
    }

    #[test]
    fn probe_reply_intercept_matches_and_swallows_only_armed_probe() {
        let _guard = probe_test_guard();

        let src = Ipv4Addr::new(172, 19, 0, 1);
        let dns = Ipv4Addr::new(172, 19, 0, 2);
        let query_pkt = build_probe_packet(src, dns, 0x1234);
        // A reply frame: build_udp_reply swaps src/dst, so the frame looks
        // exactly like what lwip emits for the DNS answer (src :53 → dst
        // :PROBE_SRC_PORT) with the DNS ID leading the payload.
        let reply_payload = [0x12u8, 0x34, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0];
        let reply_pkt = build_udp_reply(&query_pkt, &reply_payload).expect("reply builds");

        // Disarmed: nothing is swallowed even for a matching frame.
        PROBE_ARMED.store(false, Ordering::SeqCst);
        probe_watch_slot().lock().take();
        assert!(
            !probe_reply_intercept(&reply_pkt),
            "disarmed → pass through"
        );

        // Armed with a DIFFERENT ID: frame passes through, watch stays armed.
        let (tx, mut rx) = oneshot::channel::<()>();
        *probe_watch_slot().lock() = Some(ProbeWatch { dns_id: 0x9999, tx });
        PROBE_ARMED.store(true, Ordering::SeqCst);
        assert!(
            !probe_reply_intercept(&reply_pkt),
            "ID mismatch → pass through"
        );
        assert!(
            probe_watch_slot().lock().is_some(),
            "mismatch must not consume the watch"
        );
        assert!(rx.try_recv().is_err(), "waiter must not be signalled");

        // Armed with the matching ID: swallowed, waiter signalled, disarmed.
        let (tx, mut rx) = oneshot::channel::<()>();
        *probe_watch_slot().lock() = Some(ProbeWatch { dns_id: 0x1234, tx });
        assert!(probe_reply_intercept(&reply_pkt), "match → swallowed");
        assert!(rx.try_recv().is_ok(), "waiter signalled on match");
        assert!(
            probe_watch_slot().lock().is_none(),
            "watch consumed on match"
        );
        assert!(
            !PROBE_ARMED.load(Ordering::SeqCst),
            "probe disarmed on match"
        );

        // Non-probe traffic (a real DNS reply to an ephemeral port) is never
        // matched even while armed.
        let (tx, _rx) = oneshot::channel::<()>();
        *probe_watch_slot().lock() = Some(ProbeWatch { dns_id: 0x1234, tx });
        PROBE_ARMED.store(true, Ordering::SeqCst);
        let other_query = synthetic_dns_query_packet(); // src port 54321, not the probe port
        let other_reply = build_udp_reply(&other_query, &reply_payload).expect("reply builds");
        assert!(
            !probe_reply_intercept(&other_reply),
            "reply to a non-probe port must pass through"
        );
        PROBE_ARMED.store(false, Ordering::SeqCst);
        probe_watch_slot().lock().take();
    }

    /// The probe's failure contract: -1 when tun2socks isn't running at all,
    /// -2 when the stack is up but no reply arrives (here: no engine DNS
    /// listener behind the intercept, so queries are dropped) — the caller's
    /// signal to restart. Uses a short deadline; the re-send loop must not
    /// spin past it.
    #[test]
    fn health_probe_reports_not_running_then_unhealthy() {
        let _lifecycle = lifecycle_test_guard();
        let _probe = probe_test_guard();

        let src = Ipv4Addr::new(172, 19, 0, 1);
        let dns = Ipv4Addr::new(172, 19, 0, 2);

        assert_eq!(
            health_probe(src, dns, 200),
            -1,
            "probe must fail fast when tun2socks is down"
        );

        unsafe extern "C" fn noop_write(
            _ctx: *mut std::os::raw::c_void,
            _data: *const u8,
            _len: usize,
        ) {
        }
        start(std::ptr::null_mut(), noop_write).expect("start");

        assert_eq!(
            health_probe(src, dns, 700),
            -2,
            "no DNS listener behind the stack → probe must time out unhealthy"
        );
        assert!(
            !PROBE_ARMED.load(Ordering::SeqCst),
            "probe must disarm after timing out"
        );
        assert!(
            probe_watch_slot().lock().is_none(),
            "watch slot must be cleared after timing out"
        );

        stop_blocking();
    }

    /// When the run task outlives `stop_blocking`'s join bound, the handle
    /// must be restored into `run_handle_slot` so the next `start()`
    /// serializes against the still-draining generation — dropping it (the
    /// old behavior) detached the task and let a new lwip NetStack overlap
    /// the old teardown. Simulated with a never-completing task standing in
    /// for a wedged teardown; costs one JOIN_TIMEOUT (5 s) of wall clock.
    #[test]
    fn stop_blocking_restores_handle_when_join_times_out() {
        let _guard = lifecycle_test_guard();

        let wedged = crate::get_tun2socks_runtime().spawn(std::future::pending::<()>());
        *run_handle_slot().lock() = Some(wedged);

        stop_blocking();

        let restored = run_handle_slot().lock().take();
        assert!(
            restored.is_some(),
            "timed-out join must put the handle back for the next start()"
        );
        restored.expect("checked above").abort();
    }
}
