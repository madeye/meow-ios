//! Rust half of the meow-ios native stack.
//!
//! Ported from `mihomo-android-ffi` by replacing the JNI shim with a plain C
//! ABI. The internals (tun2socks via netstack-smoltcp, DoH client, DNS table)
//! are identical — only the entry points and the logger change.
//!
//!   TUN fd  →  netstack-smoltcp  →  SOCKS5 127.0.0.1:<port>  (Go mihomo)
//!   UDP:53  →  DoH (over the same SOCKS5)
//!
//! All sockets this crate opens are loopback, so no protect-hook is required
//! on iOS — `NEPacketTunnelProvider` already excludes the tunnel from the
//! routing table, which matches the Android `VpnService.protect()` contract.

mod dns_table;
mod doh_client;
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

/// Directory where the active profile's `config.yaml` lives. The DoH client
/// reads it to discover the user-configured DoH server list.
pub(crate) static HOME_DIR: Mutex<Option<String>> = Mutex::new(None);

// Thread-local last error (kept identical to the Android build so clients can
// migrate with no behavior change).
thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_error(msg: String) {
    let cstr = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|e| *e.borrow_mut() = cstr);
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
/// `dir` must point to a NUL-terminated UTF-8 string or be NULL. The crate
/// copies the value — the caller is free to free the buffer on return.
#[no_mangle]
pub unsafe extern "C" fn meow_tun_set_home_dir(dir: *const c_char) {
    let parsed = if dir.is_null() {
        None
    } else {
        CStr::from_ptr(dir).to_str().ok().map(str::to_owned)
    };
    logging::bridge_log(&format!("meow_tun_set_home_dir: {:?}", parsed));
    *HOME_DIR.lock() = parsed.filter(|s| !s.is_empty());
}

/// Start tun2socks on `fd`, relaying TCP through SOCKS5 `127.0.0.1:socks_port`
/// and intercepting UDP DNS on port 53 via DoH (routed through the same SOCKS
/// proxy). `dns_port` is accepted for API parity with the Android build but
/// ignored — iOS uses a DNS resolver the TUN settings expose on the gateway.
///
/// Returns 0 on success, -1 on error (inspect `meow_tun_last_error`).
#[no_mangle]
pub extern "C" fn meow_tun_start(fd: c_int, socks_port: c_int, dns_port: c_int) -> c_int {
    logging::bridge_log(&format!(
        "meow_tun_start: fd={}, socks={}, dns={}",
        fd, socks_port, dns_port
    ));

    if fd < 0 {
        set_error("invalid file descriptor".to_string());
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
