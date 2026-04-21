//! Rust half of the meow-ios native stack — a single C ABI that the
//! PacketTunnel extension and the main app both link against via
//! `MihomoCore.xcframework`.
//!
//! Architecture mirrors the madeye/meow Android FFI (mihomo-android-ffi):
//!
//!   NEPacketTunnelFlow ⇆ mpsc ⇆ netstack-smoltcp ──► SOCKS5 ──► MixedListener
//!                                                               │
//!                                                               ▼
//!                                                     mihomo_tunnel adapters
//!                                                     (rules / proxies / DNS)
//!
//! The `MixedListener` runs inside the extension on `127.0.0.1:<mixed-port>`
//! and accepts SOCKS5 and HTTP proxy traffic. tun2socks opens a SOCKS5
//! connection to that listener for every TCP flow it accepts from netstack.
//! DoH POSTs traverse the same listener via reqwest's `socks5h://` proxy, so
//! DNS is subject to the same rule/proxy-group decisions as regular traffic.
//!
//! UDP through netstack is disabled (matching Android); only UDP DNS is
//! intercepted pre-stack and answered via DoH. Non-DNS UDP is dropped.

mod diagnostics;
mod dns_table;
mod doh_client;
mod engine;
mod listener;
mod logging;
mod subscription;
mod tun2socks;

#[cfg(test)]
mod xdg_home_dir_tests;

use parking_lot::Mutex;
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::OnceLock;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

pub(crate) fn get_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        // 4 workers, not 2. Observed under load: during a burst of concurrent
        // TLS dials + DoH resolutions + /configs or /providers handler work,
        // the previous 2-worker runtime could starve — both workers busy on
        // serde/TLS CPU work while new TCP flows queued up, eventually the
        // tunnel stopped making progress (same PID, no death, just frozen).
        // 4 gives the scheduler enough headroom on iPhone 17 Pro without
        // meaningfully increasing resident memory (per-worker stack is ~2 MB
        // of virtual address space, not committed).
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("failed to create tokio runtime")
    })
}

pub(crate) static HOME_DIR: Mutex<Option<String>> = Mutex::new(None);

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_error(msg: String) {
    let cstr = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|e| *e.borrow_mut() = cstr);
}

unsafe fn cstr_to_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}

/// Copy `src` into `out`/`out_cap` with a NUL terminator. Returns the number
/// of bytes needed (not counting the NUL); callers allocate `ret + 1` and
/// retry if the return exceeds `out_cap`.
unsafe fn write_out(src: &[u8], out: *mut c_char, out_cap: c_int) -> c_int {
    let needed = src.len();
    if !out.is_null() && out_cap > 0 {
        let cap = (out_cap as usize).saturating_sub(1);
        let n = std::cmp::min(cap, needed);
        std::ptr::copy_nonoverlapping(src.as_ptr(), out as *mut u8, n);
        *out.add(n) = 0;
    }
    needed as c_int
}

// ---------------------------------------------------------------------------
// Lifecycle / logging (shared surface)
// ---------------------------------------------------------------------------

/// Initialize logging. Safe to call more than once.
#[no_mangle]
pub extern "C" fn meow_core_init() {
    logging::init_os_logger();
    logging::bridge_log("meow_core_init: os_log initialized");
}

/// Set the app-group container path where config.yaml and cache files live.
/// `dir` may be NULL or empty.
///
/// Also exports `$XDG_CONFIG_HOME=<dir>` into the process env so `mihomo-config`
/// finds its GeoIP database at `<dir>/mihomo/Country.mmdb` (upstream mihomo's
/// resolution order is `$XDG_CONFIG_HOME/mihomo/` → `$HOME/.config/mihomo/`).
/// iOS sandbox HOME has no `.config`, so the env var is how the bundled Country.mmdb
/// lands on the engine's load path.
///
/// # Safety
/// `dir` must point to a NUL-terminated UTF-8 string or be NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_core_set_home_dir(dir: *const c_char) {
    let parsed = cstr_to_str(dir).map(str::to_owned).filter(|s| !s.is_empty());
    logging::bridge_log(&format!("meow_core_set_home_dir: {:?}", parsed));
    if let Some(ref d) = parsed {
        // SAFETY: `std::env::set_var` is safe in edition 2021 (the unsafe-by-default
        // shift is edition 2024 only, see rust-lang/rust#124636). Callers invoke
        // this at process startup (AppModel.init / TunnelEngine.start) *before*
        // the tokio runtime or any engine thread spawns, so no concurrent env
        // reader races with this write.
        std::env::set_var("XDG_CONFIG_HOME", d);
    }
    *HOME_DIR.lock() = parsed;
}

/// Return the last error message for the calling thread. The pointer is
/// owned by the crate and valid until the next error is set on the same
/// thread — copy immediately if retention is needed.
#[no_mangle]
pub extern "C" fn meow_core_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

// ---------------------------------------------------------------------------
// Engine (mihomo-rust) — lifecycle + config
// ---------------------------------------------------------------------------

/// Start the mihomo-rust engine using the YAML at `config_path`. Idempotent.
/// Returns 0 on success, -1 on error (inspect `meow_core_last_error`).
///
/// # Safety
/// `config_path` must point to a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_start(config_path: *const c_char) -> c_int {
    let Some(path) = cstr_to_str(config_path) else {
        set_error("config_path is null or not utf-8".into());
        return -1;
    };
    logging::bridge_log(&format!("meow_engine_start: {}", path));
    match engine::start(path) {
        Ok(()) => 0,
        Err(e) => {
            set_error(format!("engine start failed: {}", e));
            -1
        }
    }
}

/// Stop the mihomo-rust engine. Idempotent.
#[no_mangle]
pub extern "C" fn meow_engine_stop() {
    logging::bridge_log("meow_engine_stop");
    engine::stop();
}

/// Returns 1 if the engine is running, 0 otherwise.
#[no_mangle]
pub extern "C" fn meow_engine_is_running() -> c_int {
    if engine::is_running() {
        1
    } else {
        0
    }
}

/// Validate a Clash YAML config. Returns 0 on success, -1 on error.
///
/// # Safety
/// `yaml` must point to `len` bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_validate_config(yaml: *const c_char, len: c_int) -> c_int {
    if yaml.is_null() || len <= 0 {
        set_error("empty yaml".into());
        return -1;
    }
    let slice = std::slice::from_raw_parts(yaml as *const u8, len as usize);
    let Ok(text) = std::str::from_utf8(slice) else {
        set_error("yaml is not utf-8".into());
        return -1;
    };
    match engine::validate(text) {
        Ok(()) => 0,
        Err(e) => {
            set_error(format!("invalid config: {}", e));
            -1
        }
    }
}

/// Write cumulative upload/download byte counters. Safe to call before
/// `meow_engine_start` — returns zero counters.
///
/// # Safety
/// Pointers, if non-NULL, must reference writable 64-bit integer slots.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_traffic(out_upload: *mut i64, out_download: *mut i64) {
    let (up, down) = engine::traffic();
    if !out_upload.is_null() {
        *out_upload = up;
    }
    if !out_download.is_null() {
        *out_download = down;
    }
}

// ---------------------------------------------------------------------------
// Subscription conversion
// ---------------------------------------------------------------------------

/// Convert a subscription body (Clash YAML, or base64-wrapped / plain v2rayN
/// URI list) to Clash YAML. Writes NUL-terminated UTF-8 into `out`/`out_cap`.
/// Returns the total bytes needed (not counting NUL); if the return exceeds
/// `out_cap`, the output was truncated — allocate `ret + 1` and retry.
/// Returns -1 on error (inspect `meow_core_last_error`).
///
/// # Safety
/// `body` must reference `len` bytes; `out` must reference `out_cap` bytes
/// if non-NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_convert_subscription(
    body: *const c_char,
    len: c_int,
    out: *mut c_char,
    out_cap: c_int,
) -> c_int {
    if body.is_null() || len <= 0 {
        set_error("empty subscription body".into());
        return -1;
    }
    let slice = std::slice::from_raw_parts(body as *const u8, len as usize);
    match subscription::convert(slice) {
        Ok(yaml) => write_out(yaml.as_bytes(), out, out_cap),
        Err(e) => {
            set_error(format!("convert failed: {}", e));
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Measure direct TCP connect latency to `host:port`. Writes elapsed ms into
/// `out_ms`; returns 0 on success, -1 on error.
///
/// # Safety
/// `host` must be NUL-terminated; `out_ms` must be writable.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_test_direct_tcp(
    host: *const c_char,
    port: c_int,
    timeout_ms: c_int,
    out_ms: *mut i64,
) -> c_int {
    let Some(h) = cstr_to_str(host) else {
        set_error("host is null or not utf-8".into());
        return -1;
    };
    let to = Duration::from_millis(timeout_ms.max(1) as u64);
    let result = get_runtime().block_on(diagnostics::test_direct_tcp(h, port as u16, to));
    match result {
        Ok(elapsed) => {
            if !out_ms.is_null() {
                *out_ms = elapsed.as_millis() as i64;
            }
            0
        }
        Err(e) => {
            set_error(e.to_string());
            -1
        }
    }
}

/// HTTP reachability via the engine's default (direct) adapter.
///
/// # Safety
/// `url` must be NUL-terminated; outputs may be NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_test_proxy_http(
    url: *const c_char,
    timeout_ms: c_int,
    out_status: *mut c_int,
    out_ms: *mut i64,
) -> c_int {
    let Some(u) = cstr_to_str(url) else {
        set_error("url is null or not utf-8".into());
        return -1;
    };
    let Some(tunnel) = engine::tunnel() else {
        set_error("engine not running".into());
        return -1;
    };
    let to = Duration::from_millis(timeout_ms.max(1) as u64);
    let result = get_runtime().block_on(diagnostics::test_proxy_http(&tunnel, u, to));
    match result {
        Ok((status, elapsed)) => {
            if !out_status.is_null() {
                *out_status = status as c_int;
            }
            if !out_ms.is_null() {
                *out_ms = elapsed.as_millis() as i64;
            }
            0
        }
        Err(e) => {
            set_error(e.to_string());
            -1
        }
    }
}

/// Resolve `host` via the engine resolver. Writes comma-separated IPs into
/// `out`/`out_cap` (same truncation rules as `meow_engine_convert_subscription`).
///
/// # Safety
/// `host` must be NUL-terminated; `out` must reference `out_cap` bytes if
/// non-NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_test_dns(
    host: *const c_char,
    timeout_ms: c_int,
    out: *mut c_char,
    out_cap: c_int,
) -> c_int {
    let Some(h) = cstr_to_str(host) else {
        set_error("host is null or not utf-8".into());
        return -1;
    };
    let Some(tunnel) = engine::tunnel() else {
        set_error("engine not running".into());
        return -1;
    };
    let to = Duration::from_millis(timeout_ms.max(1) as u64);
    match get_runtime().block_on(diagnostics::test_dns(&tunnel, h, to)) {
        Ok(ips) => {
            let joined = ips
                .iter()
                .map(|ip| ip.to_string())
                .collect::<Vec<_>>()
                .join(",");
            write_out(joined.as_bytes(), out, out_cap)
        }
        Err(e) => {
            set_error(e.to_string());
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// tun2socks (NEPacketTunnelFlow bridge) — netstack → SOCKS5 loopback
// ---------------------------------------------------------------------------

/// C-compatible egress callback. Called from the tokio runtime whenever
/// tun2socks produces a packet bound for Swift's `NEPacketTunnelFlow`. Swift
/// guarantees `ctx` remains live between `meow_tun_start` and `meow_tun_stop`.
pub type MeowWritePacket =
    unsafe extern "C" fn(ctx: *mut std::os::raw::c_void, data: *const u8, len: usize);

/// Start tun2socks with a Swift-owned egress callback. The ingest side is
/// driven by `meow_tun_ingest`; the tunnel uses an internal mpsc queue so
/// there's no file descriptor between Swift and Rust.
///
/// `socks_port` is the loopback port where the mihomo mixed listener is
/// bound (see `meow_engine_start`). Pass `0` to inherit the engine's port —
/// the FFI resolves it via `engine::mixed_port()`. If the engine isn't
/// running yet, the call fails.
///
/// Returns 0 on success, -1 on error (inspect `meow_core_last_error`).
///
/// # Safety
/// `ctx` is opaque to Rust but must remain valid for any dispatch that occurs
/// between this call and `meow_tun_stop`. `write_cb` must be a non-null C
/// function pointer that stays valid for the lifetime of the tunnel.
#[no_mangle]
pub unsafe extern "C" fn meow_tun_start(
    ctx: *mut std::os::raw::c_void,
    write_cb: MeowWritePacket,
    socks_port: u16,
) -> c_int {
    let port = if socks_port == 0 {
        match engine::mixed_port() {
            Some(p) => p,
            None => {
                set_error("meow_tun_start: engine not running, cannot infer socks_port".into());
                return -1;
            }
        }
    } else {
        socks_port
    };
    logging::bridge_log(&format!("meow_tun_start: socks_port={}", port));
    match tun2socks::start(ctx, write_cb, port) {
        Ok(()) => 0,
        Err(e) => {
            logging::bridge_log(&format!("meow_tun_start ERROR: {}", e));
            set_error(e);
            -1
        }
    }
}

/// Feed a raw IP packet from `NEPacketTunnelFlow.readPackets` into the
/// netstack. Returns 0 if the packet was queued (or dropped under backpressure),
/// -1 if tun2socks isn't running. Non-blocking; callers shouldn't hold
/// `readPackets` completion handlers waiting.
///
/// # Safety
/// `data` must reference `len` bytes of readable memory.
#[no_mangle]
pub unsafe extern "C" fn meow_tun_ingest(data: *const u8, len: usize) -> c_int {
    if data.is_null() || len == 0 {
        return 0;
    }
    let slice = std::slice::from_raw_parts(data, len);
    tun2socks::ingest(slice)
}

/// Stop the tun2socks task. Idempotent.
#[no_mangle]
pub extern "C" fn meow_tun_stop() {
    logging::bridge_log("meow_tun_stop");
    tun2socks::stop();
}
