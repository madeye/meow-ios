//! Rust half of the meow-ios native stack.
//!
//! Embeds the mihomo-rust proxy engine and the tun2socks layer in a single
//! static library that links into the iOS PacketTunnel extension.
//!
//!   NEPacketTunnelFlow  ⇆  socketpair  ⇆  netstack-smoltcp  ⇆  SOCKS5 loopback
//!                                                              ↑
//!                                               mihomo-rust (MixedListener)
//!                                                    ↓
//!                                         rules / proxies / DNS / REST API
//!
//! All sockets this crate opens are loopback, so no protect-hook is required
//! on iOS — NEPacketTunnelProvider already excludes the tunnel sockets from
//! the routing table.

mod dns_table;
mod doh_client;
mod engine;
mod logging;
mod tun2socks;

use parking_lot::Mutex;
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::OnceLock;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

pub(crate) fn get_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
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

// ---------------------------------------------------------------------------
// C ABI — callable from Swift via MeowCore/include/mihomo_ios_ffi.h
// ---------------------------------------------------------------------------

/// Initialize logging. Safe to call more than once.
#[no_mangle]
pub extern "C" fn meow_tun_init() {
    logging::init_os_logger();
    logging::bridge_log("meow_tun_init: os_log initialized");
}

/// Set the directory where the active profile's config.yaml lives. `dir` may
/// be NULL or empty, in which case the DoH client falls back to built-in
/// nameservers.
///
/// # Safety
/// `dir` must point to a NUL-terminated UTF-8 string or be NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_tun_set_home_dir(dir: *const c_char) {
    let parsed = cstr_to_str(dir).map(str::to_owned).filter(|s| !s.is_empty());
    logging::bridge_log(&format!("meow_tun_set_home_dir: {:?}", parsed));
    *HOME_DIR.lock() = parsed;
}

// ---------------------------------------------------------------------------
// Engine (mihomo-rust)
// ---------------------------------------------------------------------------

/// Start the mihomo-rust engine using the YAML at `config_path`. Idempotent.
/// Returns 0 on success, -1 on error (inspect `meow_tun_last_error`).
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

/// Validate a Clash YAML config. Returns 0 if it parses, -1 otherwise
/// (inspect `meow_tun_last_error`).
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

/// Write the engine's cumulative upload/download byte counters into the
/// caller-provided slots. NULL pointers are skipped. Safe to call before
/// `meow_engine_start`; returns zero counters.
///
/// # Safety
/// `out_upload` / `out_download`, if non-NULL, must point to writable 64-bit
/// integer slots.
#[no_mangle]
pub unsafe extern "C" fn meow_engine_traffic(
    out_upload: *mut i64,
    out_download: *mut i64,
) {
    let (up, down) = engine::traffic();
    if !out_upload.is_null() {
        *out_upload = up;
    }
    if !out_download.is_null() {
        *out_download = down;
    }
}

// ---------------------------------------------------------------------------
// tun2socks (NEPacketTunnelFlow bridge)
// ---------------------------------------------------------------------------

/// Start tun2socks on `fd`, relaying TCP through SOCKS5 `127.0.0.1:socks_port`
/// and UDP DNS via DoH (routed through the same SOCKS proxy). `dns_port` is
/// accepted for API parity but ignored — iOS uses the DNS resolver exposed by
/// `NEPacketTunnelNetworkSettings`.
///
/// Returns 0 on success, -1 on error (inspect `meow_tun_last_error`).
#[no_mangle]
pub extern "C" fn meow_tun_start(fd: c_int, socks_port: c_int, dns_port: c_int) -> c_int {
    logging::bridge_log(&format!(
        "meow_tun_start: fd={}, socks={}, dns={}",
        fd, socks_port, dns_port
    ));
    if fd < 0 {
        set_error("invalid file descriptor".into());
        return -1;
    }
    match tun2socks::start(fd, socks_port as u16, dns_port as u16) {
        Ok(()) => 0,
        Err(e) => {
            logging::bridge_log(&format!("meow_tun_start ERROR: {}", e));
            set_error(e);
            -1
        }
    }
}

/// Stop the tun2socks task. Idempotent.
#[no_mangle]
pub extern "C" fn meow_tun_stop() {
    logging::bridge_log("meow_tun_stop");
    tun2socks::stop();
}

/// Return the last error message for the calling thread. Pointer is owned by
/// the crate and valid until the next error is set on the same thread — copy
/// it immediately if you need to retain it.
#[no_mangle]
pub extern "C" fn meow_tun_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}
