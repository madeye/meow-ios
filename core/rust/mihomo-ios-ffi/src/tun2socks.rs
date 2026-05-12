//! tun2socks using netstack-smoltcp: Swift pushes raw IP packets in via
//! [`ingest`], netstack terminates TCP and UDP sessions in a userspace
//! smoltcp stack, and each flow dispatches directly into
//! `mihomo_tunnel::{tcp,udp}::handle_*` — no SOCKS5 loopback, no cross-process
//! hop.
//!
//! Egress packets (netstack output) are handed back to Swift via a C
//! callback registered in [`start`]. No file descriptors cross the FFI.
//!
//! DNS lives in `crate::fake_ip_dns::handle_query`, invoked inline from the
//! ingress loop below. NEDNSSettings advertises a TUN-subnet address as the
//! system resolver, so every UDP DNS query arrives as an in-TUN IP packet;
//! we intercept it pre-stack, run it through the handler, and inject the
//! reply back into the egress channel with src/dst + ports swapped. No UDP
//! listener socket exists — there's nothing for one to listen on.
//!
//! TCP/UDP destination IPs come back as fake-IPs from the
//! `crate::fake_ip` pool; both `dispatch_tcp` and `dispatch_udp` reverse
//! them to hostnames before populating `metadata.host`, so mihomo's
//! rule/proxy chain sees the original qname rather than the synthetic IP.

use crate::logging;
use futures::{SinkExt, StreamExt};
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use mihomo_tunnel::tunnel::TunnelInner;
use mihomo_tunnel::udp::UdpSession;
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
use tokio::sync::{mpsc, Semaphore};
use tracing::{info, trace, warn};

use netstack_smoltcp::{udp::UdpMsg, AnyIpPktFrame, StackBuilder, TcpStream as NetstackTcpStream};

/// Matches the cbindgen-emitted typedef in `mihomo_core.h`: Rust calls this
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
pub(crate) static ACTIVE_TCP_CONNS: std::sync::atomic::AtomicI64 =
    std::sync::atomic::AtomicI64::new(0);

// TCP flows have no accept-time burst cap: every smoltcp-accepted flow is
// dispatched. Memory is bounded instead by the 30-second idle sweeper
// (`TCP_IDLE_SECS`) plus the hourly registry-size watchdog below — the cap
// was a defensive backstop for an earlier "bursty-on-flow" leak that has
// since been chased back to its real cause.
//
// UDP and DNS keep their accept-time burst caps because their listeners
// don't have an equivalent registry / idle-sweeper to bound growth.
const TCP_IDLE_SECS: u64 = 90;
const TCP_IDLE_SWEEP_INTERVAL_SECS: u64 = 30;
const UDP_BURST_CAP: usize = 512;

// Hourly watchdog: belt-and-suspenders backstop on the live `tcp_flows()`
// registry. Once an hour, if the registry exceeds
// `TCP_HOURLY_WATCHDOG_THRESHOLD` (e.g. a runaway reconnect storm or a leaked
// abort handle) abort *every* flow in the table. Aggressive, but the
// alternative is sitting at jetsam risk for another 59 minutes.
const TCP_HOURLY_WATCHDOG_INTERVAL_SECS: u64 = 3600;
const TCP_HOURLY_WATCHDOG_THRESHOLD: usize = 1024;

static UDP_CAP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

static TCP_FLOW_ID_SEQ: AtomicU64 = AtomicU64::new(1);

/// Per-active-flow timestamp. The Arc-shared cell lets `IdleTrackingConn`
/// bump `last_active_ms` on every successful poll without taking the
/// global flow-table lock; the sweep reader walks the table to compare.
struct FlowState {
    last_active_ms: AtomicU64,
}

/// Registry entry for one in-flight TCP flow. Aborting `abort` drops the
/// `dispatch_tcp` future, which closes both halves of the relay — the
/// netstack stream side and the in-process mihomo dispatch (whichever
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

/// Walk the flow table and abort any flow whose `last_active_ms` is older
/// than `TCP_IDLE_SECS`. Called from the periodic sweeper. Returns the
/// number of evicted flows.
fn sweep_idle_tcp_flows() -> usize {
    let cutoff = now_ms().saturating_sub(TCP_IDLE_SECS * 1000);
    let mut evicted: Vec<(u64, SocketAddr, SocketAddr)> = Vec::new();
    tcp_flows().retain(|&id, rec| {
        if rec.state.last_active_ms.load(Ordering::Relaxed) <= cutoff {
            rec.abort.abort();
            evicted.push((id, rec.src, rec.dst));
            false
        } else {
            true
        }
    });
    if !evicted.is_empty() {
        warn!(
            "tun2socks: evicted {} idle TCP flows (>{}s)",
            evicted.len(),
            TCP_IDLE_SECS
        );
        for (id, src, dst) in &evicted {
            logging::bridge_log(&format!(
                "tun2socks: TCP idle-evict {} {} -> {}",
                id, src, dst
            ));
        }
    }
    evicted.len()
}

/// Abort every flow in the registry. Same `abort()` semantics as the idle
/// sweeper — dropping the `dispatch_tcp` future closes both halves of the
/// relay. Returns the number of flows closed. Used by the hourly watchdog
/// when the live count exceeds `TCP_HOURLY_WATCHDOG_THRESHOLD`.
fn close_all_tcp_flows() -> usize {
    let flows = tcp_flows();
    let mut closed: Vec<(u64, SocketAddr, SocketAddr)> = Vec::with_capacity(flows.len());
    flows.retain(|&id, rec| {
        rec.abort.abort();
        closed.push((id, rec.src, rec.dst));
        false
    });
    if !closed.is_empty() {
        warn!(
            "tun2socks: hourly watchdog closed {} TCP flows",
            closed.len()
        );
        for (id, src, dst) in &closed {
            logging::bridge_log(&format!(
                "tun2socks: TCP watchdog-close {} {} -> {}",
                id, src, dst
            ));
        }
    }
    closed.len()
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

fn ingress_slot() -> &'static Mutex<Option<mpsc::Sender<Vec<u8>>>> {
    static S: OnceLock<Mutex<Option<mpsc::Sender<Vec<u8>>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

pub fn start(ctx: *mut c_void, cb: WritePacketFn) -> Result<(), String> {
    if TUN2SOCKS_RUNNING.swap(true, Ordering::SeqCst) {
        return Err("tun2socks already running".into());
    }

    let emitter = EgressEmitter {
        ctx: EmitCtx(ctx),
        cb,
    };

    info!("tun2socks starting (direct-callback ingest)");

    let (ingress_tx, ingress_rx) = mpsc::channel::<Vec<u8>>(256);
    *ingress_slot().lock() = Some(ingress_tx);

    let rt = crate::get_runtime();
    rt.spawn(async move {
        if let Err(e) = run_tun2socks(ingress_rx, emitter).await {
            logging::bridge_log(&format!("tun2socks error: {}", e));
        }
        ingress_slot().lock().take();
        TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
        info!("tun2socks exited");
    });

    Ok(())
}

pub fn stop() {
    TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
    // Dropping the sender terminates the ingress task on its next `recv()`.
    ingress_slot().lock().take();
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
    logging::bridge_log("tun2socks: building netstack-smoltcp stack");

    let (mut stack, tcp_runner, udp_socket, tcp_listener) = StackBuilder::default()
        .enable_tcp(true)
        .enable_udp(true)
        .stack_buffer_size(1024)
        .tcp_buffer_size(512)
        .build()?;

    let tcp_runner = tcp_runner.expect("TCP runner");
    let mut tcp_listener = tcp_listener.expect("TCP listener");
    let udp_socket = udp_socket.expect("UDP socket");
    let (mut udp_read, udp_write) = udp_socket.split();

    let (udp_reply_tx, mut udp_reply_rx) = mpsc::channel::<UdpMsg>(256);
    // NAT key mirrors mihomo-tunnel's `NatTable = DashMap<(SocketAddr, SocketAddr), Arc<UdpSession>>`
    // post-ADR-0008 Direction-A refactor. We must key reader spawns on the
    // same tuple mihomo-tunnel uses, or dedupe breaks and we leak readers.
    let reply_readers: Arc<Mutex<HashSet<(SocketAddr, SocketAddr)>>> =
        Arc::new(Mutex::new(HashSet::new()));

    let (stack_ingress_tx, mut stack_ingress_rx) = mpsc::channel::<AnyIpPktFrame>(256);
    let (egress_tx, mut egress_rx) = mpsc::channel::<Vec<u8>>(1024);

    let udp_sem = Arc::new(Semaphore::new(UDP_BURST_CAP));

    let runner_handle = tokio::spawn(async move {
        if let Err(e) = tcp_runner.await {
            logging::bridge_log(&format!("tun2socks: TCP runner error: {}", e));
        }
    });

    let egress_tx_stack = egress_tx.clone();
    let stack_handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                pkt = stack_ingress_rx.recv() => {
                    match pkt {
                        Some(frame) => {
                            if let Err(e) = stack.send(frame).await {
                                logging::bridge_log(&format!("stack send error: {}", e));
                                break;
                            }
                        }
                        None => break,
                    }
                }
                pkt = stack.next() => {
                    match pkt {
                        Some(Ok(frame)) => { let _ = egress_tx_stack.try_send(frame); }
                        Some(Err(e)) => {
                            logging::bridge_log(&format!("stack recv error: {}", e));
                            break;
                        }
                        None => break,
                    }
                }
            }
        }
    });

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
            logging::bridge_log(&format!("tun2socks: TCP {} -> {}", local_addr, remote_addr));

            let flow_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
            let state = Arc::new(FlowState {
                last_active_ms: AtomicU64::new(now_ms()),
            });
            let state_for_task = state.clone();
            let task = tokio::spawn(async move {
                dispatch_tcp(stream, local_addr, remote_addr, state_for_task).await;
                tcp_flows().remove(&flow_id);
            });
            tcp_flows().insert(
                flow_id,
                FlowRecord {
                    state,
                    abort: task.abort_handle(),
                    src: local_addr,
                    dst: remote_addr,
                },
            );
        }
    });

    // Periodic idle sweeper: catches flows that have gone idle while no new
    // accepts are arriving (e.g. background apps with long-lived sockets that
    // haven't said anything recently). Cancelled at tun2socks shutdown.
    let idle_sweeper_handle = tokio::spawn(async move {
        let mut tick =
            tokio::time::interval(std::time::Duration::from_secs(TCP_IDLE_SWEEP_INTERVAL_SECS));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // First tick fires immediately; skip it so we don't churn at startup.
        tick.tick().await;
        loop {
            tick.tick().await;
            if !TUN2SOCKS_RUNNING.load(Ordering::Relaxed) {
                break;
            }
            sweep_idle_tcp_flows();
        }
    });

    // Hourly watchdog: if the flow registry has crept past the threshold,
    // close everything. Read the count off `tcp_flows()` directly (the
    // registry is the source of truth — `ACTIVE_TCP_CONNS` is incremented
    // inside `dispatch_tcp` and can briefly disagree at flow boundaries).
    let watchdog_handle = tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(
            TCP_HOURLY_WATCHDOG_INTERVAL_SECS,
        ));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // Skip the immediate first tick so we don't fire right at startup.
        tick.tick().await;
        loop {
            tick.tick().await;
            if !TUN2SOCKS_RUNNING.load(Ordering::Relaxed) {
                break;
            }
            let live = tcp_flows().len();
            if live > TCP_HOURLY_WATCHDOG_THRESHOLD {
                warn!(
                    "tun2socks: hourly watchdog tripped: {} live TCP flows > {} threshold, closing all",
                    live, TCP_HOURLY_WATCHDOG_THRESHOLD
                );
                close_all_tcp_flows();
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
        let mut udp_write = udp_write;
        while let Some(msg) = udp_reply_rx.recv().await {
            if let Err(e) = udp_write.send(msg).await {
                logging::bridge_log(&format!("tun2socks: UDP reply send error: {}", e));
                break;
            }
        }
    });

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
                        "tun2socks: UDP burst cap reached, dropping datagram",
                    );
                    continue;
                }
            };
            let reply_tx = udp_reply_tx_accept.clone();
            let readers = reply_readers_accept.clone();
            tokio::spawn(async move {
                let _permit = permit;
                dispatch_udp(payload, src, dst, reply_tx, readers).await;
            });
        }
    });

    while let Some(ip_data) = ingress_rx.recv().await {
        if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
            break;
        }

        // Fake-IP mode: NEDNSSettings advertises a TUN-subnet IP
        // (172.19.0.2) as the system DNS server, so every UDP DNS query
        // arrives here as an in-TUN IP packet. Hand it to
        // `fake_ip_dns::handle_query`, swap src/dst + ports on the reply,
        // and inject the response packet straight into the egress channel
        // — never let it touch the smoltcp stack (the destination IP isn't
        // a real host on the inside, and we'd just create an orphan
        // session).
        if parse_udp_packet(&ip_data).is_some_and(|p| p.dst_port == 53) {
            let request = ip_data.clone();
            let egress = egress_tx.clone();
            tokio::spawn(async move {
                let Some(resolver) = crate::fake_ip_dns::resolver() else {
                    trace!("tun2socks: UDP/53 query dropped — resolver not yet published");
                    return;
                };
                let Some(parsed) = parse_udp_packet(&request) else {
                    return;
                };
                let Some(response_payload) =
                    crate::fake_ip_dns::handle_query(parsed.payload, &resolver).await
                else {
                    return;
                };
                let Some(reply_pkt) = build_udp_reply(&request, &response_payload) else {
                    return;
                };
                let _ = egress.send(reply_pkt).await;
            });
            continue;
        }

        match stack_ingress_tx.try_send(ip_data) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(frame)) => {
                let _ = stack_ingress_tx.send(frame).await;
            }
            Err(mpsc::error::TrySendError::Closed(_)) => break,
        }
    }

    runner_handle.abort();
    stack_handle.abort();
    tcp_accept_handle.abort();
    idle_sweeper_handle.abort();
    watchdog_handle.abort();
    udp_accept_handle.abort();
    udp_writer_handle.abort();
    egress_handle.abort();
    drop(udp_reply_tx);

    // Abort any TCP flows still held in the registry so the in-process
    // mihomo dispatch tasks don't outlive the tunnel.
    let flows = tcp_flows();
    for entry in flows.iter() {
        entry.abort.abort();
    }
    flows.clear();

    logging::bridge_log("tun2socks: exiting");
    Ok(())
}

// ---------------------------------------------------------------------------
// In-process TCP dispatch into mihomo_tunnel
// ---------------------------------------------------------------------------

/// RAII guard that decrements `ACTIVE_TCP_CONNS` on drop. Replaces the
/// manual `fetch_add` / `fetch_sub` pair so the counter stays balanced
/// when `dispatch_tcp` is dropped mid-`.await` — i.e. when the idle
/// sweeper, the hourly watchdog, or the tunnel-shutdown loop calls
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

    // Reverse the fake-IP back to the hostname captured at DNS-allocation
    // time. A miss means the flow is targeting a literal IP the client
    // dialed directly (no DNS round trip) — let mihomo's rule engine see
    // the real `dst_ip` and route by IP rules.
    let (host, dst_ip) = match crate::fake_ip::pool().reverse_lookup(dst.ip()) {
        Some(hostname) => (hostname, None),
        None => (String::new(), Some(dst.ip())),
    };

    dispatch_tcp_via_mihomo(stream, src, dst, state, tunnel, host, dst_ip).await;
}

async fn dispatch_tcp_via_mihomo(
    stream: NetstackTcpStream,
    src: SocketAddr,
    dst: SocketAddr,
    state: Arc<FlowState>,
    tunnel: mihomo_tunnel::Tunnel,
    host: String,
    dst_ip: Option<std::net::IpAddr>,
) {
    let metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Inner,
        src_ip: Some(src.ip()),
        src_port: src.port(),
        dst_ip,
        dst_port: dst.port(),
        host: host.into(),
        ..Default::default()
    };

    let conn: Box<dyn ProxyConn> = Box::new(IdleTracking {
        inner: NetstackConn(stream),
        state,
    });
    mihomo_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata).await;
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
/// the mihomo path (`IdleTracking<NetstackConn>`, served as a
/// `Box<dyn ProxyConn>` to `mihomo_tunnel::tcp::handle_tcp`). The CN-IP
/// direct-bypass relay that used the same wrapper over a raw
/// `tokio::net::TcpStream` was removed when DNS moved to fake-IP mode —
/// every TCP flow now goes through `dispatch_tcp_via_mihomo`.
struct IdleTracking<T> {
    inner: T,
    state: Arc<FlowState>,
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
        if matches!(poll, Poll::Ready(Ok(()))) && buf.filled().len() > before {
            self.touch();
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

// `ProxyConn` only matters on the mihomo path (the trait is consumed by
// `mihomo_tunnel::tcp::handle_tcp`); scope the impl to the netstack flavor so
// the CN-IP-direct wrapper doesn't have to invent a `remote_destination()`.
impl ProxyConn for IdleTracking<NetstackConn> {
    fn remote_destination(&self) -> String {
        self.inner.remote_destination()
    }
}

// ---------------------------------------------------------------------------
// In-process UDP dispatch into mihomo_tunnel
//
// `mihomo_tunnel::udp::handle_udp` installs the outbound session into the NAT
// table on the first packet of a flow but does not drive the reply side — the
// caller owns the reader loop. We key replies on the same NAT key
// mihomo-tunnel uses internally (`"{src}:{remote_address}"`) so reader
// spawns stay deduped without a second source of truth.
// ---------------------------------------------------------------------------

async fn dispatch_udp(
    payload: Vec<u8>,
    src: SocketAddr,
    dst: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
    reply_readers: Arc<Mutex<HashSet<(SocketAddr, SocketAddr)>>>,
) {
    let Some(tunnel) = crate::engine::tunnel() else {
        logging::bridge_log("tun2socks: engine not running, dropping UDP datagram");
        return;
    };

    // Same fake-IP reverse as the TCP path: hand mihomo the hostname when
    // we have one, otherwise let the engine route on the literal IP.
    let (host, dst_ip) = match crate::fake_ip::pool().reverse_lookup(dst.ip()) {
        Some(hostname) => (hostname, None),
        None => (String::new(), Some(dst.ip())),
    };

    let mut metadata = Metadata {
        network: Network::Udp,
        conn_type: ConnType::Inner,
        src_ip: Some(src.ip()),
        src_port: src.port(),
        dst_ip,
        dst_port: dst.port(),
        host: host.into(),
        ..Default::default()
    };

    // ADR-0008 post-Direction-A NAT key: (src SocketAddr, resolved dst
    // SocketAddr). mihomo-tunnel calls `pre_resolve` internally before
    // inserting into `nat_table`; we must match its output exactly or the
    // subsequent `nat_table.get(&key)` misses. `host` was already populated
    // above from the fake-IP pool reverse-lookup, so `pre_resolve` just
    // resolves it through the engine resolver and fills `dst_ip` — same
    // call mihomo would make internally, kept idempotent on second invoke.
    tunnel.inner().pre_resolve(&mut metadata).await;
    let Some(resolved_ip) = metadata.dst_ip else {
        // Resolution failed — handle_udp will also bail, nothing to dispatch.
        return;
    };
    let key = (src, SocketAddr::new(resolved_ip, metadata.dst_port));

    mihomo_tunnel::udp::handle_udp(tunnel.inner(), &payload, src, metadata).await;

    if !reply_readers.lock().insert(key) {
        return;
    }

    let inner = tunnel.inner().clone();
    let Some(session) = inner.nat_table.get(&key).map(|r| r.value().clone()) else {
        // handle_udp bailed before NAT insert (no matching rule / dial error).
        reply_readers.lock().remove(&key);
        return;
    };

    spawn_udp_reply_reader(key, session, src, dst, reply_tx, reply_readers, inner);
}

fn spawn_udp_reply_reader(
    key: (SocketAddr, SocketAddr),
    session: Arc<UdpSession>,
    app_src: SocketAddr,
    app_dst: SocketAddr,
    reply_tx: mpsc::Sender<UdpMsg>,
    reply_readers: Arc<Mutex<HashSet<(SocketAddr, SocketAddr)>>>,
    tunnel_inner: Arc<TunnelInner>,
) {
    tokio::spawn(async move {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match session.conn.read_packet(&mut buf).await {
                Ok((n, _from)) => {
                    // Reply injection: the IP frame handed back to the app
                    // must look like it came FROM the external peer (app_dst)
                    // TO the app (app_src). netstack's Sink builds the header
                    // from (src, dst) in that argument order.
                    let msg: UdpMsg = (buf[..n].to_vec(), app_dst, app_src);
                    // UDP is inherently lossy; drop if writer is backed up
                    // rather than accumulating unbounded Vec<u8> allocations.
                    if reply_tx.try_send(msg).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    info!("UDP reply reader closing for {:?}: {}", key, e);
                    break;
                }
            }
        }
        tunnel_inner.nat_table.remove(&key);
        reply_readers.lock().remove(&key);
    });
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

    /// All tests in this module mutate the process-wide `tcp_flows()`
    /// registry. Default `cargo test` parallelism races them; serialize
    /// through a single guard so they observe a clean slate.
    fn flows_test_guard() -> std::sync::MutexGuard<'static, ()> {
        static GUARD: StdMutex<()> = StdMutex::new(());
        GUARD.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn dummy_addr(port: u16) -> SocketAddr {
        SocketAddr::new(std::net::IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), port)
    }

    /// Spawns a no-op task purely so we have a real `AbortHandle` to put in
    /// `FlowRecord`. The test only inspects whether `sweep_idle_tcp_flows`
    /// removes entries by timestamp; we don't care if abort actually fires.
    fn dummy_handle() -> tokio::task::AbortHandle {
        tokio::runtime::Handle::current()
            .spawn(std::future::pending::<()>())
            .abort_handle()
    }

    #[tokio::test]
    async fn sweep_evicts_only_idle_flows() {
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
                    last_active_ms: AtomicU64::new(now.saturating_sub((TCP_IDLE_SECS + 5) * 1000)),
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

        let evicted = sweep_idle_tcp_flows();
        assert_eq!(evicted, 1, "only the stale flow should be swept");
        assert!(flows.get(&stale_id).is_none(), "stale flow removed");
        assert!(flows.get(&fresh_id).is_some(), "fresh flow retained");

        flows.clear();
    }

    #[tokio::test]
    async fn sweep_with_no_flows_is_a_no_op() {
        let _guard = flows_test_guard();
        let flows = tcp_flows();
        flows.clear();
        assert_eq!(sweep_idle_tcp_flows(), 0);
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
                    last_active_ms: AtomicU64::new(now.saturating_sub((TCP_IDLE_SECS + 5) * 1000)),
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
}
