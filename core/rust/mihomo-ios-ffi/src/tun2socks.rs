//! tun2socks using netstack-smoltcp: Swift pushes raw IP packets in via
//! [`ingest`], netstack terminates TCP and UDP sessions in a userspace
//! smoltcp stack, and each flow dispatches directly into
//! `mihomo_tunnel::{tcp,udp}::handle_*` — no SOCKS5 loopback, no cross-process
//! hop.
//!
//! Egress packets (netstack output + DNS replies) are handed back to Swift via
//! a C callback registered in [`start`]. No file descriptors cross the FFI.
//! UDP DNS is short-circuited pre-stack to a plain-TCP DNS client (still
//! routed through mihomo's proxy chain); non-DNS UDP flows through
//! netstack's `UdpSocket` into `mihomo_tunnel::udp::handle_udp`, and a
//! per-NAT-session reader drains proxy replies back through netstack's
//! `WriteHalf` so the IP packet emitted to Swift is synthesized with
//! source = external peer.

use crate::dns_client;
use crate::dns_table;
use crate::logging;
use futures::{SinkExt, StreamExt};
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use mihomo_tunnel::tunnel::TunnelInner;
use mihomo_tunnel::udp::UdpSession;
use parking_lot::Mutex;
use std::collections::HashSet;
use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::os::raw::c_void;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{mpsc, Semaphore};
use tracing::{info, warn};

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

// Burst caps: defensive backstop against the "bursty-on-flow" leak that lets a
// reconnect storm (DNS lookups + pent-up connect attempts from every
// backgrounded app) blow past the 50 MiB NE memory ceiling before any flow
// completes. Drops at the accept boundary; peers see RST / packet loss for a
// few hundred ms instead of the whole tunnel dying.
//
// `TCP_BURST_CAP` is a hard memory backstop sitting above `TCP_SOFT_CAP`.
// The soft cap (512) is the one users normally hit: when reached, idle flows
// (>= TCP_IDLE_SECS without any byte movement) are evicted at accept time
// and by a periodic sweeper, freeing both their burst-cap permits and the
// upstream SOCKS5 connection mihomo's relay was holding open. The hard cap
// only fires if eviction can't free enough room — a real overload.
const TCP_BURST_CAP: usize = 1024;
const TCP_SOFT_CAP: usize = 512;
const TCP_IDLE_SECS: u64 = 90;
const TCP_IDLE_SWEEP_INTERVAL_SECS: u64 = 30;
const UDP_BURST_CAP: usize = 512;
const DNS_BURST_CAP: usize = 256;

static TCP_CAP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);
static UDP_CAP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);
static DNS_CAP_LOG_LAST_MS: AtomicU64 = AtomicU64::new(0);

static TCP_FLOW_ID_SEQ: AtomicU64 = AtomicU64::new(1);

/// Per-active-flow timestamp. The Arc-shared cell lets `IdleTrackingConn`
/// bump `last_active_ms` on every successful poll without taking the
/// global flow-table lock; the sweep reader walks the table to compare.
struct FlowState {
    last_active_ms: AtomicU64,
}

/// Registry entry for one in-flight TCP flow. Aborting `abort` drops the
/// `dispatch_tcp` future, which closes both halves of the relay — the
/// netstack stream and the upstream SOCKS5 connection mihomo opened — and
/// returns the burst-cap permit when the held `_permit` is dropped.
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
/// than `TCP_IDLE_SECS`. Called at accept time when the soft cap is hit and
/// from the periodic sweeper. Returns the number of evicted flows.
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
            logging::bridge_log(&format!("tun2socks: TCP idle-evict {} {} -> {}", id, src, dst));
        }
    }
    evicted.len()
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
    // TCP DNS dispatches per-request through `mihomo_tunnel::tcp::handle_tcp`
    // — same in-process Rust-to-Rust path as netstack TCP flows below — so no
    // loopback port is involved.
    dns_client::init_dns_client();

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

    let tcp_sem = Arc::new(Semaphore::new(TCP_BURST_CAP));
    let udp_sem = Arc::new(Semaphore::new(UDP_BURST_CAP));
    let dns_sem = Arc::new(Semaphore::new(DNS_BURST_CAP));

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

    let tcp_sem_accept = tcp_sem.clone();
    let tcp_accept_handle = tokio::spawn(async move {
        while let Some((stream, local_addr, remote_addr)) = tcp_listener.next().await {
            // Soft cap: reaching 512 active flows triggers an idle sweep
            // before we commit to admitting the new flow. Eviction frees
            // burst-cap permits along with the upstream SOCKS5 connections
            // those flows held, so the subsequent acquire usually succeeds.
            if ACTIVE_TCP_CONNS.load(Ordering::Relaxed) >= TCP_SOFT_CAP as i64 {
                sweep_idle_tcp_flows();
            }

            let permit = match tcp_sem_accept.clone().try_acquire_owned() {
                Ok(p) => p,
                Err(_) => {
                    warn_capped(
                        &TCP_CAP_LOG_LAST_MS,
                        "tun2socks: TCP burst cap reached, dropping flow",
                    );
                    drop(stream);
                    continue;
                }
            };
            logging::bridge_log(&format!("tun2socks: TCP {} -> {}", local_addr, remote_addr));

            let flow_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
            let state = Arc::new(FlowState {
                last_active_ms: AtomicU64::new(now_ms()),
            });
            let state_for_task = state.clone();
            let task = tokio::spawn(async move {
                let _permit = permit;
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

    let dns_reply_tx = egress_tx.clone();
    while let Some(ip_data) = ingress_rx.recv().await {
        if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
            break;
        }

        if let Some((src_ip, src_port, dst_ip, dst_port, payload)) = parse_udp_packet(&ip_data) {
            if dst_port == 53 {
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
                let reply_tx = dns_reply_tx.clone();
                let query = payload.to_vec();
                tokio::spawn(async move {
                    let _permit = permit;
                    handle_dns_query(src_ip, src_port, dst_ip, dst_port, query, reply_tx).await;
                });
                continue;
            }
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
    udp_accept_handle.abort();
    udp_writer_handle.abort();
    egress_handle.abort();
    drop(udp_reply_tx);

    // Abort any TCP flows still held in the registry so the burst-cap
    // semaphore + upstream SOCKS5 connections don't outlive the tunnel.
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

async fn dispatch_tcp(
    stream: NetstackTcpStream,
    src: SocketAddr,
    dst: SocketAddr,
    state: Arc<FlowState>,
) {
    ACTIVE_TCP_CONNS.fetch_add(1, Ordering::Relaxed);
    let Some(tunnel) = crate::engine::tunnel() else {
        logging::bridge_log("tun2socks: engine not running, dropping TCP flow");
        ACTIVE_TCP_CONNS.fetch_sub(1, Ordering::Relaxed);
        return;
    };

    let (host, dst_ip) = match dns_table::dns_table_lookup(dst.ip()) {
        // `fake-ip` / `redir-host` scenarios: the netstack receives a synthetic
        // destination IP and we recover the real hostname from the DNS cache.
        Some(hostname) => (hostname, None),
        None => (String::new(), Some(dst.ip())),
    };

    let metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Inner,
        src_ip: Some(src.ip()),
        src_port: src.port(),
        dst_ip,
        dst_port: dst.port(),
        host,
        ..Default::default()
    };

    let conn: Box<dyn ProxyConn> = Box::new(IdleTrackingConn {
        inner: NetstackConn(stream),
        state,
    });
    mihomo_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata).await;
    ACTIVE_TCP_CONNS.fetch_sub(1, Ordering::Relaxed);
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

/// Wraps `NetstackConn` to bump `FlowState::last_active_ms` on every poll
/// that returned `Ready(Ok(_))`. The stamp covers both directions because
/// mihomo's relay drives this end's `poll_read` (bytes from the app) and
/// `poll_write` (bytes from the upstream proxy) on the same wrapper.
/// Pending / would-block polls are intentionally not counted as activity.
struct IdleTrackingConn {
    inner: NetstackConn,
    state: Arc<FlowState>,
}

impl IdleTrackingConn {
    fn touch(&self) {
        self.state.last_active_ms.store(now_ms(), Ordering::Relaxed);
    }
}

impl AsyncRead for IdleTrackingConn {
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

impl AsyncWrite for IdleTrackingConn {
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

impl ProxyConn for IdleTrackingConn {
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

    let (host, dst_ip) = match dns_table::dns_table_lookup(dst.ip()) {
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
        host,
        ..Default::default()
    };

    // ADR-0008 post-Direction-A NAT key: (src SocketAddr, resolved dst
    // SocketAddr). mihomo-tunnel calls `pre_resolve` internally before
    // inserting into `nat_table`; we must match its output exactly or the
    // subsequent `nat_table.get(&key)` misses. Calling `pre_resolve` here
    // (same method handle_udp would call) guarantees parity for fake-ip /
    // host-mode flows — it's idempotent once `dst_ip` is populated.
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
// UDP helpers (DNS short-circuit to TCP DNS)
// ---------------------------------------------------------------------------

fn parse_udp_packet(ip_data: &[u8]) -> Option<(u32, u16, u32, u16, &[u8])> {
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
    let src_ip = u32::from_ne_bytes([ip_data[12], ip_data[13], ip_data[14], ip_data[15]]);
    let dst_ip = u32::from_ne_bytes([ip_data[16], ip_data[17], ip_data[18], ip_data[19]]);
    let src_port = u16::from_be_bytes([ip_data[ihl], ip_data[ihl + 1]]);
    let dst_port = u16::from_be_bytes([ip_data[ihl + 2], ip_data[ihl + 3]]);
    let udp_len = u16::from_be_bytes([ip_data[ihl + 4], ip_data[ihl + 5]]) as usize;
    let start = ihl + 8;
    let end = (ihl + udp_len).min(ip_data.len());
    if start > end {
        return None;
    }
    Some((src_ip, src_port, dst_ip, dst_port, &ip_data[start..end]))
}

fn build_udp_packet(
    src_ip: u32,
    src_port: u16,
    dst_ip: u32,
    dst_port: u16,
    payload: &[u8],
) -> Vec<u8> {
    let udp_len = 8 + payload.len();
    let total_len = 20 + udp_len;
    let mut p = vec![0u8; total_len];
    p[0] = 0x45;
    p[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
    p[6] = 0x40;
    p[8] = 64;
    p[9] = 17;
    p[12..16].copy_from_slice(&src_ip.to_ne_bytes());
    p[16..20].copy_from_slice(&dst_ip.to_ne_bytes());
    let ck = ip_checksum(&p[..20]);
    p[10..12].copy_from_slice(&ck.to_be_bytes());
    p[20..22].copy_from_slice(&src_port.to_be_bytes());
    p[22..24].copy_from_slice(&dst_port.to_be_bytes());
    p[24..26].copy_from_slice(&(udp_len as u16).to_be_bytes());
    p[28..].copy_from_slice(payload);
    p
}

fn ip_checksum(h: &[u8]) -> u16 {
    let mut s: u32 = 0;
    for i in (0..h.len()).step_by(2) {
        s += if i + 1 < h.len() {
            (h[i] as u32) << 8 | h[i + 1] as u32
        } else {
            (h[i] as u32) << 8
        };
    }
    while s >> 16 != 0 {
        s = (s & 0xFFFF) + (s >> 16);
    }
    !s as u16
}

async fn handle_dns_query(
    src_ip: u32,
    src_port: u16,
    dst_ip: u32,
    dst_port: u16,
    query: Vec<u8>,
    reply_tx: mpsc::Sender<Vec<u8>>,
) {
    let name = dns_table::parse_dns_query_name(&query).unwrap_or_default();
    logging::bridge_log(&format!(
        "DNS: {} from {:?}:{}",
        name,
        Ipv4Addr::from(src_ip.to_ne_bytes()),
        src_port
    ));

    if let Some(response) = crate::china_dns::resolve(&query).await {
        for (ip, hostname, ttl) in dns_table::parse_dns_response_records(&response) {
            dns_table::dns_table_insert(ip, hostname, ttl);
        }
        let _ = reply_tx.try_send(build_udp_packet(
            dst_ip, dst_port, src_ip, src_port, &response,
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

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
        let flows = tcp_flows();
        flows.clear();

        let now = now_ms();
        let stale_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);
        let fresh_id = TCP_FLOW_ID_SEQ.fetch_add(1, Ordering::Relaxed);

        flows.insert(
            stale_id,
            FlowRecord {
                state: Arc::new(FlowState {
                    last_active_ms: AtomicU64::new(
                        now.saturating_sub((TCP_IDLE_SECS + 5) * 1000),
                    ),
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
        let flows = tcp_flows();
        flows.clear();
        assert_eq!(sweep_idle_tcp_flows(), 0);
    }
}
