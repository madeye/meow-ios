//! `meow-utun` — developer-only macOS end-to-end test harness for the
//! `meow-ios-ffi` crate.
//!
//! Bridges the same C-ABI surface the iOS PacketTunnelProvider drives
//! (`meow_core_*`, `meow_engine_*`, `meow_tun_*`) into a real macOS `utun`
//! interface, so the engine + fake-IP DNS + CN-bypass + tun2socks
//! dispatch paths can be exercised with actual packets without an iPhone
//! and without going through the iOS Simulator (which has no TUN host).
//!
//! Usage (sudo required because utun + ifconfig + route need privileges):
//!
//!     sudo ./target/debug/meow-utun \
//!         --config /path/to/effective-config.yaml \
//!         --home   /path/to/app-group-home
//!
//! The binary itself only opens utun, plumbs packets, and starts the
//! engine. **Interface IP, MTU, and routes must be configured externally**
//! — once the binary prints `utun ready as utunN`, in another shell:
//!
//!     # In-TUN address (matches the iOS NEPacketTunnelNetworkSettings):
//!     sudo ifconfig utunN 172.19.0.1 172.19.0.2 mtu 1500 up
//!     # Route the world through the tunnel (be sure to exclude SSH if remote!):
//!     sudo route -n add -net 0.0.0.0/1 172.19.0.2
//!     sudo route -n add -net 128.0.0.0/1 172.19.0.2
//!     # DNS:
//!     sudo networksetup -setdnsservers Wi-Fi 172.19.0.2
//!
//! On Ctrl-C the binary stops the engine + tun2socks, closes the utun fd
//! (kernel removes the interface), and exits.

mod utun;

use anyhow::{Context, Result};
use clap::Parser;
use std::ffi::CString;
use std::os::fd::RawFd;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::thread;
use tracing::{error, info, warn};
use utun::Utun;

// Pull the FFI surface in as normal Rust items via the rlib. The same
// symbols are exported with C linkage from the staticlib that iOS links,
// so we are exercising the exact bytes the PacketTunnel extension runs.
use meow_ios_ffi::{
    debug_counts, meow_core_init, meow_core_last_error, meow_core_set_home_dir, meow_engine_start,
    meow_engine_stop, meow_tun_ingest, meow_tun_set_accept_cap,
    meow_tun_set_udp_first_reply_deadline_ms, meow_tun_start, meow_tun_stop, rss,
};

#[derive(Parser, Debug)]
#[command(name = "meow-utun", about = "macOS utun harness for meow-ios-ffi")]
struct Args {
    /// Path to an iOS-style effective-config.yaml. The same file the
    /// PacketTunnel extension hands to `meow_engine_start`; produced by
    /// `meow_patch_config` from a user subscription, or hand-written.
    #[arg(long)]
    config: String,

    /// Home directory used as XDG_CONFIG_HOME (the engine reads
    /// `<home>/meow/Country.mmdb`, `<home>/meow/cn-ipv*.bin`, etc.).
    /// Mirror the AppGroup container layout.
    #[arg(long)]
    home: String,

    /// Specific utun unit (e.g. `7` for `utun7`). 0 = kernel picks the
    /// first free unit.
    #[arg(long, default_value_t = 0)]
    unit: u32,

    /// If > 0, sample resident memory every N seconds and log it. Use
    /// this to chart the FFI's RSS curve under whatever traffic shape
    /// the operator drives through the tun. Cheap (one mach_task call
    /// per tick); leave at 0 for normal interactive runs.
    #[arg(long, default_value_t = 0)]
    rss_monitor_interval_secs: u64,

    /// If set, spawn a background load generator that opens
    /// `stress_conns` concurrent TCP connections to this host:port,
    /// holds each open for `stress_hold_ms`, then closes and repeats.
    /// All originate from the harness process — under a default
    /// `route add -net 0.0.0.0/1 172.19.0.2` they enter the tun and
    /// drive real flow churn through the engine, surfacing per-flow
    /// memory leaks that the cargo integration test can't see.
    #[arg(long)]
    stress_target: Option<String>,

    /// Concurrent connections held open by the stress loop. Ignored
    /// when `--stress-target` is unset.
    #[arg(long, default_value_t = 32)]
    stress_conns: usize,

    /// Per-connection hold time before the stress loop tears it down
    /// and reopens. Short holds (≤200 ms) maximise churn per second.
    #[arg(long, default_value_t = 200)]
    stress_hold_ms: u64,

    /// Total wall time the stress loop runs before exiting. 0 = run
    /// until Ctrl-C.
    #[arg(long, default_value_t = 0)]
    stress_duration_secs: u64,

    /// Per-tunnel TCP accept cap (max concurrent in-flight flows the
    /// engine will dispatch). 0 = leave at the FFI default (128).
    /// Lowering this caps the steady-state per-flow buffer footprint.
    #[arg(long, default_value_t = 0)]
    tcp_accept_cap: i32,

    /// If set, spawn a UDP load generator that fires datagrams at this
    /// `host:port` from a FRESH ephemeral source port each time. Every
    /// datagram is therefore a new `(src,dst)` 5-tuple — exactly what makes
    /// the engine insert a new `Arc<UdpSession>` into its NAT table. This is
    /// the load shape the slow-leak hunt identified (TCP churn does NOT
    /// exercise it). Point it at the engine's DNS (or any UDP responder) to
    /// also get replies, which exercises the "one reply then quiet" path.
    /// Independent of `--stress-target`; both may run together.
    #[arg(long)]
    udp_stress_target: Option<String>,

    /// Concurrent UDP sender threads. Ignored when `--udp-stress-target`
    /// is unset.
    #[arg(long, default_value_t = 32)]
    udp_stress_conns: usize,

    /// Per-worker delay between datagrams. Lower = higher 5-tuple churn
    /// per second (≈ `udp_stress_conns / interval`/s new NAT sessions).
    #[arg(long, default_value_t = 20)]
    udp_stress_interval_ms: u64,

    /// If set, SYNTHETICALLY inject IPv4/UDP packets straight into the
    /// engine via `meow_tun_ingest` — bypassing the OS route table, system
    /// DNS, and the utun device entirely. Each injected packet carries a
    /// fresh `(src_ip,src_port)`, so the engine inserts a new `Arc<UdpSession>`
    /// into its NAT table per packet. Use a REAL, reachable dst that won't
    /// answer the chosen UDP port (e.g. `8.8.8.8:4433`): DIRECT dial succeeds
    /// (so the session is created), no reply ever arrives (so it goes idle),
    /// and the egress goes out the default route — no fake-IP, no DNS loop,
    /// no routing loop. This is the deterministic way to drive the UDP NAT
    /// leak path; `--udp-stress-target` (socket-based) needs fake-IP routing.
    /// dst port MUST NOT be 53 (that hits the DNS intercept, not the NAT).
    #[arg(long)]
    udp_inject_target: Option<String>,

    /// Synthetic-injection rate in packets/sec (each = one new NAT session).
    /// Steady-state live sessions ≈ rate × 60s idle window once the sweeper
    /// is reaping. Ignored unless `--udp-inject-target` is set.
    #[arg(long, default_value_t = 50)]
    udp_inject_rate: u64,

    /// Override the FFI's UDP first-reply deadline (ms). -1 leaves the FFI
    /// default (10_000). Set to 0 to DISABLE it, so a session that never
    /// replies is NOT reaped at the deadline — it then relies on the 60s NAT
    /// sweeper / post-first-reply idle timeout. This isolates the sweeper as
    /// the bounding mechanism: with the fix `nat_table` plateaus at
    /// ~rate×60s; without it, it grows unbounded (the leak).
    #[arg(long, default_value_t = -1)]
    udp_first_reply_deadline_ms: i32,
}

/// The egress callback runs on a tokio worker thread (inside the FFI's
/// runtime). It needs to write the packet back to the same utun fd this
/// process opened. We stash the raw fd in a global `AtomicI32` because the
/// callback type is a plain `extern "C" fn` — no closure environment.
///
/// A sentinel of -1 means "no utun installed yet"; writes during that
/// window are silently dropped (start-up race, shouldn't happen once
/// `meow_tun_start` returns).
static EGRESS_FD: AtomicI32 = AtomicI32::new(-1);
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

/// Trampoline matching the FFI's `MeowWritePacket` signature. Writes the
/// (already-built) IP packet back to utun with the macOS AF prefix dance.
unsafe extern "C" fn egress_callback(_ctx: *mut c_void, data: *const u8, len: usize) {
    if data.is_null() || len == 0 {
        return;
    }
    let fd = EGRESS_FD.load(Ordering::Relaxed);
    if fd < 0 {
        return;
    }
    // SAFETY: caller guarantees `data` is readable for `len` bytes during the
    // call; we do not retain the slice past return.
    let slice = std::slice::from_raw_parts(data, len);
    if let Err(e) = write_egress(fd, slice) {
        warn!("egress write failed: {}", e);
    }
}

fn write_egress(fd: RawFd, ip_packet: &[u8]) -> Result<()> {
    // Reuse the Utun writer logic without owning the fd. Constructing a
    // temporary Utun would close the fd on drop — we want shared ownership
    // for the callback path, so write here via a free helper.
    use libc::{c_void, write, AF_INET, AF_INET6};
    if ip_packet.is_empty() {
        return Ok(());
    }
    let af: u32 = match ip_packet[0] >> 4 {
        4 => AF_INET as u32,
        6 => AF_INET6 as u32,
        other => anyhow::bail!("egress: unknown IP version nibble {other}"),
    };
    let mut frame = Vec::with_capacity(4 + ip_packet.len());
    frame.extend_from_slice(&af.to_be_bytes());
    frame.extend_from_slice(ip_packet);
    // SAFETY: fd is valid for the lifetime of the engine session; `frame`
    // is readable for frame.len() bytes.
    let n = unsafe { write(fd, frame.as_ptr() as *const c_void, frame.len()) };
    if n < 0 {
        return Err(std::io::Error::last_os_error()).context("write(utun)");
    }
    if (n as usize) != frame.len() {
        anyhow::bail!("short write to utun: {} of {}", n, frame.len());
    }
    Ok(())
}

fn last_ffi_error() -> String {
    // `meow_core_last_error` returns a thread-local pointer owned by the FFI;
    // valid until the next error is set on this thread.
    let p = meow_core_last_error();
    if p.is_null() {
        return "<unknown>".into();
    }
    // SAFETY: pointer is to a NUL-terminated C string per FFI contract.
    unsafe { std::ffi::CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned()
}

fn install_signal_handlers() -> Result<()> {
    ctrlc::set_handler(|| {
        info!("Ctrl-C received, shutting down…");
        SHUTDOWN.store(true, Ordering::SeqCst);
    })
    .context("installing Ctrl-C handler")?;
    Ok(())
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();

    info!("opening utun (unit hint = {})…", args.unit);
    let tun = Utun::open(args.unit).context("opening utun")?;
    info!("utun ready as {}", tun.name());
    EGRESS_FD.store(tun.as_raw_fd(), Ordering::SeqCst);

    install_signal_handlers()?;

    meow_core_init();

    let home_c = CString::new(args.home.clone()).context("home contains NUL byte")?;
    // SAFETY: home_c is a valid NUL-terminated C string for the call's duration.
    unsafe { meow_core_set_home_dir(home_c.as_ptr()) };

    let config_c = CString::new(args.config.clone()).context("config path contains NUL byte")?;
    info!("starting engine with config {}", args.config);
    // SAFETY: config_c outlives the synchronous call.
    let rc = unsafe { meow_engine_start(config_c.as_ptr()) };
    if rc != 0 {
        anyhow::bail!("meow_engine_start failed: {}", last_ffi_error());
    }

    if args.tcp_accept_cap > 0 {
        let rc = meow_tun_set_accept_cap(args.tcp_accept_cap);
        if rc != 0 {
            warn!("meow_tun_set_accept_cap({}) returned {}", args.tcp_accept_cap, rc);
        } else {
            info!("tcp accept cap = {}", args.tcp_accept_cap);
        }
    }

    if args.udp_first_reply_deadline_ms >= 0 {
        let rc = meow_tun_set_udp_first_reply_deadline_ms(args.udp_first_reply_deadline_ms);
        if rc != 0 {
            warn!(
                "meow_tun_set_udp_first_reply_deadline_ms({}) returned {}",
                args.udp_first_reply_deadline_ms, rc
            );
        } else {
            info!(
                "udp first-reply deadline = {} ms{}",
                args.udp_first_reply_deadline_ms,
                if args.udp_first_reply_deadline_ms == 0 { " (disabled)" } else { "" }
            );
        }
    }

    info!("registering tun egress callback");
    // SAFETY: egress_callback matches MeowWritePacket; ctx is unused (we keep
    // shared state in EGRESS_FD instead).
    let rc = unsafe { meow_tun_start(std::ptr::null_mut(), egress_callback) };
    if rc != 0 {
        meow_engine_stop();
        anyhow::bail!("meow_tun_start failed: {}", last_ffi_error());
    }

    info!(
        "ready. Configure addresses + routes externally, then traffic on {} \
         will route through the engine. Ctrl-C to stop.",
        tun.name()
    );

    // Ingestion loop: read raw frames from utun, strip the AF prefix, and
    // feed the IP packet to `meow_tun_ingest`. The FFI hands it to the
    // netstack on a tokio worker, which eventually calls our egress
    // callback for any reply or proxied response.
    let ingest_thread = {
        let tun_fd = tun.as_raw_fd();
        thread::spawn(move || ingest_loop(tun_fd))
    };

    // Optional RSS monitor — emits one info-level line per tick with the
    // mach `resident_size` for this process. Same number jetsam compares
    // against on the device, so the curve here is directly meaningful for
    // sizing the 50 MB extension budget.
    let rss_monitor_thread = if args.rss_monitor_interval_secs > 0 {
        let interval = std::time::Duration::from_secs(args.rss_monitor_interval_secs);
        Some(thread::spawn(move || rss_monitor_loop(interval)))
    } else {
        None
    };

    // Optional load generator — drives real flow churn through the
    // engine to surface per-flow leaks the cargo integration test can't
    // see (it has no engine + no real outbound). The connections
    // originate from this process; with the standard
    // `route add -net 0.0.0.0/1 172.19.0.2` they enter the tun and walk
    // the dispatch path meow's PacketTunnel exercises on-device.
    let stress_thread = if let Some(target) = args.stress_target.clone() {
        let conns = args.stress_conns.max(1);
        let hold = std::time::Duration::from_millis(args.stress_hold_ms);
        let duration = if args.stress_duration_secs == 0 {
            None
        } else {
            Some(std::time::Duration::from_secs(args.stress_duration_secs))
        };
        info!(
            "stress: target={} conns={} hold={:?} duration={:?}",
            target, conns, hold, duration
        );
        // When a finite stress duration is set, treat its expiry as the
        // run's natural end: signal shutdown so the main park-loop unblocks
        // and the engine + utun get stopped cleanly. Without this the
        // harness keeps an idle engine alive indefinitely (rss_monitor
        // continues ticking) until Ctrl-C, padding every stress run with
        // post-load drift that the operator has to manually trim.
        let exit_after_stress = duration.is_some();
        Some(thread::spawn(move || {
            stress_loop(target, conns, hold, duration);
            if exit_after_stress {
                info!("stress: duration elapsed — signaling shutdown");
                SHUTDOWN.store(true, Ordering::SeqCst);
            }
        }))
    } else {
        None
    };

    let udp_stress_thread = if let Some(target) = args.udp_stress_target.clone() {
        let conns = args.udp_stress_conns.max(1);
        let interval = std::time::Duration::from_millis(args.udp_stress_interval_ms);
        let duration = if args.stress_duration_secs == 0 {
            None
        } else {
            Some(std::time::Duration::from_secs(args.stress_duration_secs))
        };
        info!(
            "udp_stress: target={} conns={} interval={:?} duration={:?}",
            target, conns, interval, duration
        );
        let exit_after_stress = duration.is_some();
        Some(thread::spawn(move || {
            udp_stress_loop(target, conns, interval, duration);
            if exit_after_stress {
                info!("udp_stress: duration elapsed — signaling shutdown");
                SHUTDOWN.store(true, Ordering::SeqCst);
            }
        }))
    } else {
        None
    };

    let udp_inject_thread = if let Some(target) = args.udp_inject_target.clone() {
        let rate = args.udp_inject_rate.max(1);
        let duration = if args.stress_duration_secs == 0 {
            None
        } else {
            Some(std::time::Duration::from_secs(args.stress_duration_secs))
        };
        match target.parse::<std::net::SocketAddr>() {
            Ok(dst) if dst.is_ipv4() && dst.port() != 53 => {
                info!("udp_inject: dst={} rate={}/s duration={:?}", dst, rate, duration);
                let exit_after = duration.is_some();
                Some(thread::spawn(move || {
                    udp_inject_loop(dst, rate, duration);
                    if exit_after {
                        info!("udp_inject: duration elapsed — signaling shutdown");
                        SHUTDOWN.store(true, Ordering::SeqCst);
                    }
                }))
            }
            Ok(dst) => {
                error!("udp_inject: target {} must be an IPv4 addr with port != 53", dst);
                None
            }
            Err(e) => {
                error!("udp_inject: target must be IP:port (got {:?}): {}", target, e);
                None
            }
        }
    } else {
        None
    };

    // Park the main thread on the shutdown flag; ingestion runs on its own
    // thread so a blocking utun read doesn't gate signal handling.
    while !SHUTDOWN.load(Ordering::SeqCst) {
        thread::sleep(std::time::Duration::from_millis(200));
    }

    info!("stopping tun2socks + engine…");
    meow_tun_stop();
    meow_engine_stop();
    EGRESS_FD.store(-1, Ordering::SeqCst);

    // The ingest thread is blocked in `read()`; closing the fd unblocks it
    // with EBADF. We hold the only Utun handle, so dropping it (when `main`
    // returns) closes the fd — but we want a clean join, so close
    // explicitly here.
    utun::force_close(tun.as_raw_fd());
    let _ = ingest_thread.join();
    if let Some(h) = rss_monitor_thread {
        let _ = h.join();
    }
    if let Some(h) = stress_thread {
        let _ = h.join();
    }
    if let Some(h) = udp_stress_thread {
        let _ = h.join();
    }
    if let Some(h) = udp_inject_thread {
        let _ = h.join();
    }
    info!("clean exit");
    Ok(())
}

fn rss_monitor_loop(interval: std::time::Duration) {
    let mut ticks = 0u64;
    let mut peak_mib: f64 = 0.0;
    while !SHUTDOWN.load(Ordering::Relaxed) {
        if let Some(mib) = rss::resident_mib() {
            if mib > peak_mib {
                peak_mib = mib;
            }
            // Per-flow state-map sizes alongside RSS so a multi-hour run pins
            // WHICH structure grows: nat_table + reply_readers climbing in
            // lockstep with RSS ⇒ the UDP NAT-session leak; tcp_flows flat
            // rules out the TCP path. Zeros when the engine isn't running.
            let c = debug_counts();
            info!(
                "rss_monitor t={}s rss={:.2} MiB peak={:.2} MiB tcp_flows={} reply_readers={} nat_table={}",
                ticks * interval.as_secs(),
                mib,
                peak_mib,
                c.tcp_flows,
                c.reply_readers,
                c.nat_table,
            );
        }
        ticks += 1;
        // Sleep in short slices so shutdown is responsive.
        let mut remaining = interval;
        while remaining > std::time::Duration::ZERO && !SHUTDOWN.load(Ordering::Relaxed) {
            let slice = remaining.min(std::time::Duration::from_millis(200));
            thread::sleep(slice);
            remaining = remaining.saturating_sub(slice);
        }
    }
}

/// Hammer `target` with `conns` concurrent short-lived TCP connections.
/// Each worker thread re-opens its connection as soon as the previous
/// one drops, so steady-state churn is roughly `conns / hold`/sec. Errors
/// are counted but do not stop the loop — the goal is to pin the engine
/// in steady-state flow churn while RSS is being sampled, not to assert
/// reachability.
fn stress_loop(
    target: String,
    conns: usize,
    hold: std::time::Duration,
    duration: Option<std::time::Duration>,
) {
    use std::net::ToSocketAddrs;
    use std::sync::atomic::AtomicU64;

    let started = std::time::Instant::now();
    let opened = std::sync::Arc::new(AtomicU64::new(0));
    let failed = std::sync::Arc::new(AtomicU64::new(0));

    let mut workers = Vec::with_capacity(conns);
    for _ in 0..conns {
        let target = target.clone();
        let opened = opened.clone();
        let failed = failed.clone();
        workers.push(thread::spawn(move || {
            while !SHUTDOWN.load(Ordering::Relaxed) {
                if let Some(limit) = duration {
                    if started.elapsed() >= limit {
                        return;
                    }
                }
                let addr = match target.to_socket_addrs() {
                    Ok(mut it) => it.next(),
                    Err(_) => None,
                };
                let Some(addr) = addr else {
                    failed.fetch_add(1, Ordering::Relaxed);
                    thread::sleep(std::time::Duration::from_millis(100));
                    continue;
                };
                match std::net::TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(5))
                {
                    Ok(stream) => {
                        opened.fetch_add(1, Ordering::Relaxed);
                        thread::sleep(hold);
                        drop(stream);
                    }
                    Err(_) => {
                        failed.fetch_add(1, Ordering::Relaxed);
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                }
            }
        }));
    }

    // Reporter: prints aggregate counters every 5s so the operator can
    // correlate RSS_MONITOR samples with the load profile.
    let opened_r = opened.clone();
    let failed_r = failed.clone();
    let reporter = thread::spawn(move || {
        let mut last = 0u64;
        while !SHUTDOWN.load(Ordering::Relaxed) {
            if let Some(limit) = duration {
                if started.elapsed() >= limit {
                    return;
                }
            }
            thread::sleep(std::time::Duration::from_secs(5));
            let now_o = opened_r.load(Ordering::Relaxed);
            let f = failed_r.load(Ordering::Relaxed);
            let rate = (now_o - last) as f64 / 5.0;
            info!(
                "stress: opened={} (Δ{:.1}/s) failed={} elapsed={:.0}s",
                now_o,
                rate,
                f,
                started.elapsed().as_secs_f64()
            );
            last = now_o;
        }
    });

    for w in workers {
        let _ = w.join();
    }
    let _ = reporter.join();
    info!(
        "stress: done — opened={} failed={} elapsed={:.1}s",
        opened.load(Ordering::Relaxed),
        failed.load(Ordering::Relaxed),
        started.elapsed().as_secs_f64()
    );
}

/// Fire UDP datagrams at `target` from `conns` worker threads, each using a
/// FRESH ephemeral source port per datagram so every send is a new
/// `(src,dst)` 5-tuple — exactly what makes the engine insert a new
/// `Arc<UdpSession>` into its NAT table, the per-session growth the slow
/// leak lives in (TCP churn does not touch this path). After each send the
/// worker briefly polls for a reply, so a responding target also exercises
/// the reader task's post-first-reply path. Counters reported every 5s.
fn udp_stress_loop(
    target: String,
    conns: usize,
    interval: std::time::Duration,
    duration: Option<std::time::Duration>,
) {
    use std::net::{ToSocketAddrs, UdpSocket};
    use std::sync::atomic::AtomicU64;

    let started = std::time::Instant::now();
    let sent = std::sync::Arc::new(AtomicU64::new(0));
    let failed = std::sync::Arc::new(AtomicU64::new(0));
    let replies = std::sync::Arc::new(AtomicU64::new(0));

    let mut workers = Vec::with_capacity(conns);
    for w in 0..conns {
        let target = target.clone();
        let sent = sent.clone();
        let failed = failed.clone();
        let replies = replies.clone();
        workers.push(thread::spawn(move || {
            // Folded into the payload so a DNS/echo responder sees varying
            // content (and, aimed at the engine DNS with distinct qnames,
            // churns the fake-IP pool too).
            let mut seq = 0u64;
            while !SHUTDOWN.load(Ordering::Relaxed) {
                if let Some(limit) = duration {
                    if started.elapsed() >= limit {
                        return;
                    }
                }
                let addr = match target.to_socket_addrs() {
                    Ok(mut it) => it.next(),
                    Err(_) => None,
                };
                let Some(addr) = addr else {
                    failed.fetch_add(1, Ordering::Relaxed);
                    thread::sleep(std::time::Duration::from_millis(100));
                    continue;
                };
                // Fresh socket → fresh ephemeral src port → new NAT 5-tuple.
                let sock = match UdpSocket::bind("0.0.0.0:0") {
                    Ok(s) => s,
                    Err(_) => {
                        failed.fetch_add(1, Ordering::Relaxed);
                        thread::sleep(std::time::Duration::from_millis(50));
                        continue;
                    }
                };
                let payload = [&w.to_be_bytes()[..], &seq.to_be_bytes()[..]].concat();
                seq = seq.wrapping_add(1);
                match sock.send_to(&payload, addr) {
                    Ok(_) => {
                        sent.fetch_add(1, Ordering::Relaxed);
                        let _ = sock.set_read_timeout(Some(std::time::Duration::from_millis(50)));
                        let mut buf = [0u8; 1500];
                        if sock.recv(&mut buf).is_ok() {
                            replies.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    Err(_) => {
                        failed.fetch_add(1, Ordering::Relaxed);
                    }
                }
                drop(sock);
                thread::sleep(interval);
            }
        }));
    }

    // Reporter: aggregate counters every 5s, mirroring the TCP stress loop.
    let sent_r = sent.clone();
    let failed_r = failed.clone();
    let replies_r = replies.clone();
    let reporter = thread::spawn(move || {
        let mut last = 0u64;
        while !SHUTDOWN.load(Ordering::Relaxed) {
            if let Some(limit) = duration {
                if started.elapsed() >= limit {
                    return;
                }
            }
            thread::sleep(std::time::Duration::from_secs(5));
            let now_s = sent_r.load(Ordering::Relaxed);
            let f = failed_r.load(Ordering::Relaxed);
            let r = replies_r.load(Ordering::Relaxed);
            let rate = (now_s - last) as f64 / 5.0;
            info!(
                "udp_stress: sent={} (Δ{:.1}/s) replies={} failed={} elapsed={:.0}s",
                now_s,
                rate,
                r,
                f,
                started.elapsed().as_secs_f64()
            );
            last = now_s;
        }
    });

    for w in workers {
        let _ = w.join();
    }
    let _ = reporter.join();
    info!(
        "udp_stress: done — sent={} replies={} failed={} elapsed={:.1}s",
        sent.load(Ordering::Relaxed),
        replies.load(Ordering::Relaxed),
        failed.load(Ordering::Relaxed),
        started.elapsed().as_secs_f64()
    );
}

/// Synthetic UDP NAT-churn injector. Crafts one IPv4/UDP packet per tick with
/// a fresh `(src_ip, src_port)` and feeds it straight to `meow_tun_ingest`,
/// bypassing the OS route table, system DNS, and the utun device. Each fresh
/// source is a new NAT 5-tuple the engine inserts into `nat_table`; with a
/// non-answering dst the session goes idle and the NAT sweeper must reap it.
/// Deterministic, no network setup, no fake-IP, no routing/DNS loop.
fn udp_inject_loop(dst: std::net::SocketAddr, rate: u64, duration: Option<std::time::Duration>) {
    let dst_ip = match dst.ip() {
        std::net::IpAddr::V4(v4) => v4.octets(),
        std::net::IpAddr::V6(_) => {
            error!("udp_inject: ipv6 dst unsupported");
            return;
        }
    };
    let dst_port = dst.port();
    let interval = std::time::Duration::from_secs_f64(1.0 / rate as f64);
    let started = std::time::Instant::now();
    let mut counter: u32 = 0;
    let mut injected: u64 = 0;
    let mut last_report = started;
    let payload: &[u8] = b"meow-udp-inject"; // arbitrary, non-DNS

    while !SHUTDOWN.load(Ordering::Relaxed) {
        if let Some(limit) = duration {
            if started.elapsed() >= limit {
                break;
            }
        }
        // Map the counter to a fresh (src_ip, src_port): 10.<b2>.<b1>.<b0>
        // with a 16-bit port window gives ~2^32 distinct keys before wrap —
        // far beyond any run length at these rates.
        let c = counter;
        let src_ip = [10u8, (c >> 16) as u8, (c >> 8) as u8, c as u8];
        let src_port = 1024u16.wrapping_add((c & 0xffff) as u16);
        counter = counter.wrapping_add(1);

        let pkt = build_udp_ipv4_packet(src_ip, src_port, dst_ip, dst_port, payload);
        // SAFETY: `pkt` is a valid readable slice for its length; the FFI
        // copies it into the ingress channel and does not retain the pointer.
        unsafe {
            meow_tun_ingest(pkt.as_ptr(), pkt.len());
        }
        injected += 1;

        if last_report.elapsed() >= std::time::Duration::from_secs(5) {
            info!(
                "udp_inject: injected={} (≈{:.0}/s) elapsed={:.0}s",
                injected,
                injected as f64 / started.elapsed().as_secs_f64().max(0.001),
                started.elapsed().as_secs_f64()
            );
            last_report = std::time::Instant::now();
        }
        thread::sleep(interval);
    }
    info!(
        "udp_inject: done — injected={} elapsed={:.1}s",
        injected,
        started.elapsed().as_secs_f64()
    );
}

/// One's-complement IPv4 header checksum (RFC 1071) over `header` (which must
/// carry a zeroed checksum field).
fn ipv4_checksum(header: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut i = 0;
    while i + 1 < header.len() {
        sum += u16::from_be_bytes([header[i], header[i + 1]]) as u32;
        i += 2;
    }
    if i < header.len() {
        sum += (header[i] as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

/// Build a minimal IPv4 + UDP packet (no IP options). The IP header checksum
/// is computed (the non-53 UDP path traverses the lwip netstack, which may
/// validate it); the UDP checksum is left 0, which is legal on IPv4.
fn build_udp_ipv4_packet(
    src_ip: [u8; 4],
    src_port: u16,
    dst_ip: [u8; 4],
    dst_port: u16,
    payload: &[u8],
) -> Vec<u8> {
    let udp_len: u16 = 8 + payload.len() as u16;
    let total_len: u16 = 20 + udp_len;

    let mut ip = [0u8; 20];
    ip[0] = 0x45; // version 4, IHL 5
    ip[1] = 0x00; // DSCP/ECN
    ip[2..4].copy_from_slice(&total_len.to_be_bytes());
    ip[4..6].copy_from_slice(&[0x12, 0x34]); // identification
    ip[6..8].copy_from_slice(&[0x40, 0x00]); // flags=DF, frag offset 0
    ip[8] = 64; // TTL
    ip[9] = 17; // protocol = UDP
                // ip[10..12] checksum left 0 for the computation
    ip[12..16].copy_from_slice(&src_ip);
    ip[16..20].copy_from_slice(&dst_ip);
    let cksum = ipv4_checksum(&ip);
    ip[10..12].copy_from_slice(&cksum.to_be_bytes());

    let mut pkt = Vec::with_capacity(total_len as usize);
    pkt.extend_from_slice(&ip);
    pkt.extend_from_slice(&src_port.to_be_bytes());
    pkt.extend_from_slice(&dst_port.to_be_bytes());
    pkt.extend_from_slice(&udp_len.to_be_bytes());
    pkt.extend_from_slice(&[0x00, 0x00]); // UDP checksum 0 (legal on IPv4)
    pkt.extend_from_slice(payload);
    pkt
}

fn ingest_loop(fd: RawFd) {
    let mut buf = vec![0u8; 65_536];
    loop {
        if SHUTDOWN.load(Ordering::Relaxed) {
            return;
        }
        // SAFETY: read on the utun fd is safe; buf is writable for its length.
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n < 4 {
            if SHUTDOWN.load(Ordering::Relaxed) {
                return;
            }
            let err = std::io::Error::last_os_error();
            // EBADF fires once we close the fd on shutdown.
            if err.raw_os_error() == Some(libc::EBADF) {
                return;
            }
            error!("utun read error: {}", err);
            return;
        }
        let payload = &buf[4..n as usize];
        // SAFETY: payload.as_ptr() is valid for payload.len() bytes for the
        // duration of the call; the FFI is documented as non-retaining.
        unsafe { meow_tun_ingest(payload.as_ptr(), payload.len()) };
    }
}
