//! `meow-utun` — developer-only macOS end-to-end test harness for the
//! `mihomo-ios-ffi` crate.
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
use mihomo_ios_ffi::{
    meow_core_init, meow_core_last_error, meow_core_set_home_dir, meow_engine_start,
    meow_engine_stop, meow_tun_ingest, meow_tun_start, meow_tun_stop,
};

#[derive(Parser, Debug)]
#[command(name = "meow-utun", about = "macOS utun harness for mihomo-ios-ffi")]
struct Args {
    /// Path to an iOS-style effective-config.yaml. The same file the
    /// PacketTunnel extension hands to `meow_engine_start`; produced by
    /// `meow_patch_config` from a user subscription, or hand-written.
    #[arg(long)]
    config: String,

    /// Home directory used as XDG_CONFIG_HOME (the engine reads
    /// `<home>/mihomo/Country.mmdb`, `<home>/mihomo/cn-ipv*.bin`, etc.).
    /// Mirror the AppGroup container layout.
    #[arg(long)]
    home: String,

    /// Specific utun unit (e.g. `7` for `utun7`). 0 = kernel picks the
    /// first free unit.
    #[arg(long, default_value_t = 0)]
    unit: u32,
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
    info!("clean exit");
    Ok(())
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
