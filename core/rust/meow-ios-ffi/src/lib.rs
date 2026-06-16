//! Rust half of the meow-ios native stack — unified into a single C ABI that
//! the PacketTunnel extension and the main app both link against via
//! `MeowCore.xcframework`.
//!
//! Embeds the meow-rs proxy engine and the tun2socks layer in one static
//! library. Both TCP and UDP flows are dispatched in-process:
//!
//!   NEPacketTunnelFlow ⇆ mpsc ⇆ netstack-smoltcp ⇆ meow_tunnel::{tcp,udp}::handle_*
//!                                                              ↓
//!                                          rules / proxies / DNS / REST API
//!
//! No SOCKS5 loopback sits between tun2socks and the engine; the staticlib
//! owns separate tokio runtimes for the packet/netstack driver and for meow
//! engine work so lwIP backpressure cannot starve the REST/API/proxy workers.
//! DNS is delegated end-to-end to meow's resolver running in fake-IP mode: the
//! tun2socks
//! UDP/53 intercept answers AAAA queries NOERROR-empty itself (forcing
//! clients onto the proxied IPv4 fake-IP path) and hands A queries straight
//! to `meow_dns::DnsServer::handle_query`, which synthesises the fake-IP,
//! owns the reverse mapping, and answers hosts / NXDOMAIN consistently.
//! The TCP and UDP dispatch paths then pass the literal fake-IP destination
//! to `meow_tunnel`, whose `pre_handle_metadata` reverses it back to the
//! original hostname before rule matching. The FFI no longer carries its
//! own fake-IP pool, china-DNS split-horizon, CN-IP table, DoH cache, or
//! in-FFI TCP-DNS client.

mod diagnostics;
mod engine;
mod file_log;
mod logging;
pub mod rss;
mod subscription;
mod tun2socks;

#[cfg(test)]
mod xdg_home_dir_tests;

/// Live per-flow state-map sizes (TCP flows, UDP reply readers, UDP NAT
/// table) for the dev harness RSS monitor — see the slow-leak hunt. Not part
/// of the C ABI; consumed by `macos-utun-harness` via the rlib.
pub use tun2socks::{debug_counts, DebugCounts};

use parking_lot::Mutex;
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::OnceLock;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static ENGINE_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static TUN2SOCKS_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn build_runtime(
    name: &'static str,
    worker_threads: usize,
    stack_size: usize,
) -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(worker_threads)
        .thread_name(name)
        .thread_stack_size(stack_size)
        .enable_all()
        .build()
        .unwrap_or_else(|e| panic!("failed to create {name} tokio runtime: {e}"))
}

pub(crate) fn get_engine_runtime() -> &'static tokio::runtime::Runtime {
    ENGINE_RUNTIME.get_or_init(|| {
        // Meow engine work includes REST/API, config validation, DNS resolver,
        // proxy dials, TLS, and serde. Keep two workers so heavy proxy/API
        // bursts can overlap without sharing workers with the lwIP stack.
        //
        // Stack size is 1 MiB (tokio's default is 2 MiB). This is a *virtual*
        // limit, not a resident allocation: Darwin demand-pages thread stacks,
        // so RSS tracks the deepest poll actually executed, not the cap. The
        // deeper real frames are on this runtime: BoringSSL/rustls handshakes
        // inside layered transports plus relay combinator frames.
        build_runtime("meow-engine", 2, 1024 * 1024)
    })
}

pub(crate) fn get_tun2socks_runtime() -> &'static tokio::runtime::Runtime {
    TUN2SOCKS_RUNTIME.get_or_init(|| {
        // Tun2socks owns packet ingress/egress, lwIP stack driving, and
        // accept-loop bookkeeping. It deliberately does not run meow proxy
        // dials or REST/API tasks.
        //
        // Four worker threads: the lwIP netstack is serialized by a spinning
        // `LWIP_MUTEX`, and with only two workers a contender that spins on it
        // can starve the lock holder under a startup connection burst. More
        // workers widen that window so a stuck pair can't halt all tun2socks
        // progress.
        build_runtime("meow-tun2socks", 4, 1024 * 1024)
    })
}

#[cfg(test)]
mod runtime_tests {
    fn runtime_worker_name(rt: &tokio::runtime::Runtime) -> String {
        rt.block_on(async {
            tokio::spawn(async {
                std::thread::current()
                    .name()
                    .unwrap_or("unnamed")
                    .to_string()
            })
            .await
            .expect("runtime worker name task")
        })
    }

    #[test]
    fn engine_and_tun2socks_use_distinct_tokio_worker_pools() {
        let engine = runtime_worker_name(crate::get_engine_runtime());
        let tun2socks = runtime_worker_name(crate::get_tun2socks_runtime());

        assert_eq!(engine, "meow-engine");
        assert_eq!(tun2socks, "meow-tun2socks");
        assert_ne!(engine, tun2socks);
    }
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
    logging::install_panic_hook();
    logging::bridge_log("meow_core_init: os_log initialized");
}

/// Emit a log line from the NetworkExtension host (ObjC) into the same tracing
/// pipeline the engine uses, so NE lifecycle events — start/stop, sleep/wake,
/// `reasserting`, errors — land in the App Group file log (and os_log, and the
/// REST `/logs` stream) interleaved with engine output on one timeline.
///
/// `level`: 0 = error, 1 = warn, 2 = info, 3 = debug, 4 = trace; anything else
/// is treated as info. No-op on a NULL or non-UTF-8 `msg`.
///
/// # Safety
/// `msg` must point to a NUL-terminated UTF-8 string or be NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_core_log(level: c_int, msg: *const c_char) {
    let Some(text) = cstr_to_str(msg) else {
        return;
    };
    match level {
        0 => tracing::error!(target: "ne", "{}", text),
        1 => tracing::warn!(target: "ne", "{}", text),
        3 => tracing::debug!(target: "ne", "{}", text),
        4 => tracing::trace!(target: "ne", "{}", text),
        _ => tracing::info!(target: "ne", "{}", text),
    }
}

/// Set the app-group container path where config.yaml and cache files live.
/// `dir` may be NULL or empty.
///
/// Also exports `$XDG_CONFIG_HOME=<dir>` into the process env so `meow-config`
/// finds its GeoIP database at `<dir>/meow/Country.mmdb` (upstream meow's
/// resolution order is `$XDG_CONFIG_HOME/meow/` → `$HOME/.config/meow/`).
/// iOS sandbox HOME has no `.config`, so the env var is how the bundled Country.mmdb
/// lands on the engine's load path.
///
/// # Safety
/// `dir` must point to a NUL-terminated UTF-8 string or be NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_core_set_home_dir(dir: *const c_char) {
    let parsed = cstr_to_str(dir)
        .map(str::to_owned)
        .filter(|s| !s.is_empty());
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
// Engine (meow-rs) — lifecycle + config
// ---------------------------------------------------------------------------

/// Start the meow-rs engine using the YAML at `config_path`. Idempotent.
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

/// Stop the meow-rs engine. Idempotent.
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

/// Return the number of currently active (in-flight) TCP flows dispatched
/// through the tun2socks layer. Useful for diagnosing connection accumulation.
#[no_mangle]
pub extern "C" fn meow_active_tcp_conns() -> i64 {
    // `.max(0)` defensively: `ACTIVE_TCP_CONNS` could in principle dip below
    // zero if a flow's spawn-aborted path decremented before the matching
    // increment landed. Cheap clamp keeps the FFI return non-negative even
    // if that race ever materializes.
    tun2socks::ACTIVE_TCP_CONNS
        .load(std::sync::atomic::Ordering::Relaxed)
        .max(0)
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
    let result = get_engine_runtime().block_on(diagnostics::test_direct_tcp(h, port as u16, to));
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
    let result = get_engine_runtime().block_on(diagnostics::test_proxy_http(&tunnel, u, to));
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
    match get_engine_runtime().block_on(diagnostics::test_dns(&tunnel, h, to)) {
        Ok(ips) => {
            use std::fmt::Write;
            let mut joined = String::new();
            for (i, ip) in ips.iter().enumerate() {
                if i > 0 {
                    joined.push(',');
                }
                let _ = write!(joined, "{}", ip);
            }
            write_out(joined.as_bytes(), out, out_cap)
        }
        Err(e) => {
            set_error(e.to_string());
            -1
        }
    }
}

/// Select a member proxy inside a `type: select` group, in-process —
/// the same mutation that `PUT /proxies/{group}` performs against the
/// REST API, but without the loopback hop. `group` and `name` are
/// matched against the upstream `SelectorGroup` byte-for-byte: no
/// Unicode normalization, no percent-decoding, no whitespace folding.
/// Emoji + CJK + space names therefore round-trip verbatim from YAML
/// to selector lookup, eliminating a class of bugs the URL-encoded
/// path is sensitive to.
///
/// Return codes:
/// * `0`  — selection applied.
/// * `-1` — argument is null or not valid UTF-8.
/// * `-2` — engine is not running.
/// * `-3` — group not found, or the named proxy is not a select group.
/// * `-4` — `name` is not a member of the selector.
///
/// On non-zero returns, `meow_core_last_error` carries a sanitized
/// reason suitable for surfacing in the UI.
///
/// # Safety
/// `group` and `name` must each be a NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn meow_proxy_select(group: *const c_char, name: *const c_char) -> c_int {
    let Some(group_name) = cstr_to_str(group) else {
        set_error("group is null or not utf-8".into());
        return -1;
    };
    let Some(target) = cstr_to_str(name) else {
        set_error("name is null or not utf-8".into());
        return -1;
    };
    let Some(tunnel) = engine::tunnel() else {
        set_error("engine not running".into());
        return -2;
    };
    let Some(proxy) = tunnel.proxy(group_name) else {
        set_error(format!("proxy group not found: {group_name}"));
        return -3;
    };
    let Some(selector) = proxy
        .as_any()
        .and_then(|a| a.downcast_ref::<meow_proxy::SelectorGroup>())
    else {
        set_error(format!("'{group_name}' is not a select-type group"));
        return -3;
    };
    if selector.select(target) {
        0
    } else {
        set_error(format!("'{target}' is not a member of '{group_name}'"));
        -4
    }
}

// ---------------------------------------------------------------------------
// REST-API credentials (random port + bearer secret)
// ---------------------------------------------------------------------------

/// Resolve the loopback REST-API credentials, minting them once and persisting
/// to `<home>/api-credentials.json` so the app and the packet-tunnel extension
/// — both of which patch the config — bind and authenticate with the same
/// values. The file lives in the App Group container (set via
/// `meow_core_set_home_dir`), which only this app and its extension can read,
/// so the secret never leaves the sandbox.
///
/// Falls back to an ephemeral in-memory pair if the home dir isn't set yet or
/// the file can't be read/written (e.g. first-run race) — the engine still
/// comes up authenticated; a subsequent patch will persist a stable pair.
fn api_credentials() -> (u16, String) {
    let path = HOME_DIR
        .lock()
        .clone()
        .map(|d| std::path::Path::new(&d).join("api-credentials.json"));

    if let Some(ref p) = path {
        if let Ok(bytes) = std::fs::read(p) {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                if let (Some(port), Some(secret)) = (
                    v.get("port").and_then(serde_json::Value::as_u64),
                    v.get("secret").and_then(|s| s.as_str()),
                ) {
                    if (1024..=65535).contains(&port) && !secret.is_empty() {
                        return (port as u16, secret.to_string());
                    }
                }
            }
        }
    }

    let port = random_port();
    let secret = random_hex_32();

    if let Some(ref p) = path {
        let body = serde_json::json!({ "port": port, "secret": secret }).to_string();
        // Best-effort persist; if it fails we still return the freshly-minted
        // pair so this engine start is authenticated.
        let _ = std::fs::write(p, body);
    }

    (port, secret)
}

/// Fill `buf` with OS entropy from `/dev/urandom` (always present on
/// iOS/Darwin). Avoids pulling a new RNG crate for the few bytes the
/// credential mint needs. Panics only if the device has no `/dev/urandom`,
/// which does not happen on a booted iOS system.
fn os_random(buf: &mut [u8]) {
    use std::io::Read;
    let mut f = std::fs::File::open("/dev/urandom").expect("/dev/urandom must be readable");
    f.read_exact(buf).expect("/dev/urandom read must succeed");
}

/// 16 random bytes of OS entropy, hex-encoded — a 128-bit bearer secret.
fn random_hex_32() -> String {
    let mut buf = [0u8; 16];
    os_random(&mut buf);
    let mut s = String::with_capacity(32);
    for b in buf {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// A random port in the IANA dynamic/ephemeral range (49152–65535), drawn from
/// OS entropy. Persisted, so it's stable across launches but not the
/// well-known 9090.
fn random_port() -> u16 {
    let mut buf = [0u8; 2];
    os_random(&mut buf);
    let raw = u16::from_le_bytes(buf);
    49152 + (raw % (65535 - 49152 + 1))
}

// ---------------------------------------------------------------------------
// Config patching (replaces the Swift/Yams EffectiveConfigWriter)
// ---------------------------------------------------------------------------

/// Patch a Clash YAML config for iOS: strips `dns` and `subscriptions`;
/// pins `mixed-port`; injects a hardened `external-controller` (random
/// loopback port) + random bearer `secret`; injects `geox-url` when absent.
/// Writes NUL-terminated UTF-8 into `out`/`out_cap`. Returns bytes needed (excl
/// NUL) on success; callers allocate `ret + 1` and retry if `ret >= out_cap`.
/// Returns -1 on error (inspect `meow_core_last_error`).
///
/// # Safety
/// `source_yaml` must be NUL-terminated UTF-8. `out` must reference `out_cap`
/// bytes if non-NULL.
#[no_mangle]
pub unsafe extern "C" fn meow_patch_config(
    source_yaml: *const c_char,
    mixed_port: c_int,
    out: *mut c_char,
    out_cap: c_int,
) -> c_int {
    let Some(yaml) = cstr_to_str(source_yaml) else {
        set_error("source_yaml is null or not utf-8".into());
        return -1;
    };

    let mut doc: serde_yaml::Value = match serde_yaml::from_str(yaml) {
        Ok(v) => v,
        Err(e) => {
            set_error(format!("yaml parse error: {e}"));
            return -1;
        }
    };

    let Some(root) = doc.as_mapping_mut() else {
        set_error("config root is not a yaml mapping".into());
        return -1;
    };

    // Strip `dns` (iOS pins its own resolver block) and `subscriptions`
    // (handled app-side). `secret` is intentionally NOT stripped here — we
    // overwrite it below with a per-install random token so the REST API on
    // loopback is authenticated rather than open.
    for key in ["dns", "subscriptions"] {
        root.remove(serde_yaml::Value::String(key.to_string()));
    }

    let port = if mixed_port > 0 {
        mixed_port as i64
    } else {
        7890
    };
    root.insert(
        serde_yaml::Value::String("mixed-port".into()),
        serde_yaml::Value::Number(port.into()),
    );

    // Harden the meow external-controller. It binds on loopback, but iOS
    // does not isolate 127.0.0.1 per app — any other process on the device
    // could otherwise reach an open control plane (read the running config +
    // proxy servers, dump live connections/logs, switch proxies). Two
    // mitigations, both sourced from a per-install credential file in the
    // App Group container (readable only by this app + its extension):
    //   1. a random high port instead of the well-known 9090, so the surface
    //      isn't trivially discoverable, and
    //   2. a strong random `secret`, which meow-api enforces as
    //      `Authorization: Bearer <secret>` on every route.
    // The credentials are minted once and persisted, so the app and the
    // extension (which both invoke this patch) agree on the same pair.
    let (api_port, api_secret) = api_credentials();
    root.insert(
        serde_yaml::Value::String("external-controller".into()),
        serde_yaml::Value::String(format!("127.0.0.1:{api_port}")),
    );
    root.insert(
        serde_yaml::Value::String("secret".into()),
        serde_yaml::Value::String(api_secret),
    );

    let geox_key = serde_yaml::Value::String("geox-url".into());
    if !root.contains_key(&geox_key) {
        let mut geox = serde_yaml::Mapping::new();
        for (k, v) in [
            (
                "geoip",
                "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
            ),
            (
                "mmdb",
                "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb",
            ),
            (
                "geosite",
                "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
            ),
        ] {
            geox.insert(
                serde_yaml::Value::String(k.into()),
                serde_yaml::Value::String(v.into()),
            );
        }
        root.insert(geox_key, serde_yaml::Value::Mapping(geox));
    }

    match serde_yaml::to_string(&doc) {
        Ok(s) => write_out(s.as_bytes(), out, out_cap),
        Err(e) => {
            set_error(format!("yaml serialize error: {e}"));
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// tun2socks (NEPacketTunnelFlow bridge) — dispatches in-process into engine
// ---------------------------------------------------------------------------

/// C-compatible egress callback. Called from the tun2socks tokio runtime
/// whenever tun2socks produces a packet bound for Swift's `NEPacketTunnelFlow`.
/// Swift guarantees `ctx` remains live between `meow_tun_start` and
/// `meow_tun_stop`.
pub type MeowWritePacket =
    unsafe extern "C" fn(ctx: *mut std::os::raw::c_void, data: *const u8, len: usize);

/// Start tun2socks with a Swift-owned egress callback. The ingest side is
/// driven by `meow_tun_ingest`; the tunnel uses an internal mpsc queue so
/// there's no file descriptor between Swift and Rust.
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
) -> c_int {
    logging::bridge_log("meow_tun_start (direct callback)");
    match tun2socks::start(ctx, write_cb) {
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

/// Stop the tun2socks task. Idempotent. Fire-and-forget: the run task drains
/// on the runtime after this returns. Use for suspend/resume, where the egress
/// `ctx` is retained for reuse.
#[no_mangle]
pub extern "C" fn meow_tun_stop() {
    logging::bridge_log("meow_tun_stop");
    tun2socks::stop();
}

/// Stop the tun2socks task and BLOCK until its run task (including the egress
/// callback loop) has fully torn down. Once this returns, the egress write
/// callback is guaranteed never to fire again, so the caller may safely
/// release the `ctx` it passed to `meow_tun_start` — required for a terminal
/// stop, where releasing the writer while the egress task is still draining
/// is a use-after-free. Call from a NON-runtime thread (the Swift tunnel
/// control queue). Idempotent.
#[no_mangle]
pub extern "C" fn meow_tun_stop_blocking() {
    logging::bridge_log("meow_tun_stop_blocking");
    tun2socks::stop_blocking();
}

/// Abort every in-flight TCP flow tracked by tun2socks. This is an
/// emergency diagnostic/teardown hook for dropping stale flows without
/// tearing down the engine or the TUN itself.
///
/// Each abort cancels the dispatch_tcp future, which drops the netstack
/// stream side and (via `ConnectionGuard::drop` inside meow-tunnel)
/// removes the corresponding entry from `Statistics.connections` —
/// keeping our flow registry and meow's state in sync.
///
/// UDP flows are intentionally untouched: they're connectionless from
/// the app's perspective, meow's NAT entries time out on their own,
/// and aborting them mid-flight would pointlessly drop in-flight DNS
/// replies during the interface flip.
///
/// Returns the number of flows aborted.
#[no_mangle]
pub extern "C" fn meow_tun_close_all_tcp_flows() -> c_int {
    let n = tun2socks::close_all_tcp_flows();
    logging::bridge_log(&format!("meow_tun_close_all_tcp_flows: aborted {n} flows"));
    n as c_int
}

/// Set the TCP accept-side cap. Bounds the number of concurrent
/// `dispatch_tcp` tasks live at once, which is the dominant factor in
/// peak FFI RSS under burst (1000+ concurrent dispatches each carrying
/// per-flow Metadata, Box<dyn ProxyConn>, meow outbound dial state,
/// and netstack ring buffers can push the extension past the 50 MiB
/// jetsam cap). Default 128.
///
/// Takes effect on the next `meow_tun_start`. Calls during a live
/// tunnel are accepted but do not resize the running semaphore.
///
/// Returns 0 on success, -1 on invalid input (`cap == 0`, which would
/// deadlock the accept loop).
#[no_mangle]
pub extern "C" fn meow_tun_set_accept_cap(cap: c_int) -> c_int {
    if cap <= 0 {
        set_error("accept cap must be > 0".into());
        return -1;
    }
    if tun2socks::set_accept_cap(cap as usize) {
        0
    } else {
        -1
    }
}

/// Read the currently-configured TCP accept cap. Reflects the value the
/// next `meow_tun_start` will use; does not query the running semaphore.
#[no_mangle]
pub extern "C" fn meow_tun_accept_cap() -> c_int {
    tun2socks::accept_cap() as c_int
}

/// Set the per-flow dial deadline, in milliseconds. Bounds the time
/// `dispatch_tcp` waits for the relay's first byte of progress on the
/// netstack stream before declaring the dial hung and dropping the
/// future. See docs/INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md
/// for context.
///
/// Default 10000 ms. Pass `0` to disable the watchdog (relies on the
/// 30 s idle sweeper to reap stuck flows). Negative values are rejected.
///
/// Takes effect on the next flow accepted; does not abort in-flight
/// flows mid-wait.
///
/// Returns 0 on success, -1 on invalid input.
#[no_mangle]
pub extern "C" fn meow_tun_set_dial_deadline_ms(ms: c_int) -> c_int {
    if ms < 0 {
        set_error("dial deadline must be >= 0".into());
        return -1;
    }
    tun2socks::set_dial_deadline_ms(ms as u64);
    0
}

/// Read the currently-configured per-flow dial deadline, in
/// milliseconds. `0` means the watchdog is disabled.
#[no_mangle]
pub extern "C" fn meow_tun_dial_deadline_ms() -> c_int {
    tun2socks::dial_deadline_ms() as c_int
}

/// Set the per-UDP-session first-reply deadline, in milliseconds. The
/// symmetric counterpart to `meow_tun_set_dial_deadline_ms` for the UDP
/// path — UDP doesn't connect, but iOS auto-bypass can silently drop
/// the outbound sendto when the scoped-routing cache is stale, leaving
/// the reply reader parked on `read_packet` forever. Bounding the
/// *first* reply lets us evict a dead session so the next app datagram
/// dispatches a fresh socket against a refreshed iOS route.
///
/// Default 10000 ms. Pass `0` to disable the deadline (legacy unbounded
/// behaviour — relies on meow's NAT-table TTL to reap idle sessions).
/// Negative values are rejected.
///
/// Takes effect on the next UDP session whose reply reader spawns;
/// existing readers keep their captured deadline.
///
/// Returns 0 on success, -1 on invalid input.
#[no_mangle]
pub extern "C" fn meow_tun_set_udp_first_reply_deadline_ms(ms: c_int) -> c_int {
    if ms < 0 {
        set_error("udp first-reply deadline must be >= 0".into());
        return -1;
    }
    tun2socks::set_udp_first_reply_deadline_ms(ms as u64);
    0
}

/// Read the currently-configured UDP first-reply deadline, in
/// milliseconds. `0` means the deadline is disabled.
#[no_mangle]
pub extern "C" fn meow_tun_udp_first_reply_deadline_ms() -> c_int {
    tun2socks::udp_first_reply_deadline_ms() as c_int
}

/// Set the per-TCP-flow idle TTL, in milliseconds. The complement to
/// `meow_tun_set_dial_deadline_ms` for flows whose dial *succeeded* but
/// then went permanently quiet — e.g. the upstream proxy EOF'd an idle
/// connection and the (suspended) app never FINs back, parking the relay
/// forever while it pins an accept-cap permit and an lwip pcb. Hours of
/// such accumulation exhausts the accept cap and the tunnel stops
/// passing new TCP flows ("connected but no traffic").
///
/// Default 600000 ms (10 min). Raised from the conventional 5-min proxy
/// idle timeout so no-keepalive server-push channels with multi-minute quiet
/// gaps aren't reaped while alive (2026-06-14 long-lived-TCP audit). Pass `0`
/// to disable the sweeper. Negative values are rejected.
///
/// Takes effect on the sweeper's next 30 s tick; no restart needed.
///
/// Returns 0 on success, -1 on invalid input.
#[no_mangle]
pub extern "C" fn meow_tun_set_tcp_idle_ttl_ms(ms: c_int) -> c_int {
    if ms < 0 {
        set_error("tcp idle ttl must be >= 0".into());
        return -1;
    }
    tun2socks::set_tcp_idle_ttl_ms(ms as u64);
    0
}

/// Read the currently-configured TCP idle TTL, in milliseconds. `0`
/// means the sweeper is disabled.
#[no_mangle]
pub extern "C" fn meow_tun_tcp_idle_ttl_ms() -> c_int {
    tun2socks::tcp_idle_ttl_ms() as c_int
}

/// Enable or disable "block HTTP/3 (QUIC)". Default OFF (0): current
/// behaviour is preserved. When enabled (non-zero) the tunnel drops
/// outbound UDP datagrams to destination port 443 (QUIC's transport) and
/// answers SVCB (64) / HTTPS (65) DNS queries NOERROR-empty from the
/// intercept itself (no h3/SvcParams advertisement), forcing clients onto
/// the A / fake-IPv4 + TCP path.
///
/// At the FFI layer the new value applies immediately to subsequent UDP
/// datagrams and DNS queries (the backing flag is a plain atomic). The
/// meow-ios app only invokes this at tunnel start, so toggling the user
/// preference applies on the next tunnel (re)connect — same as allowLan.
///
/// Returns 0 unconditionally.
#[no_mangle]
pub extern "C" fn meow_tun_set_block_http3(enabled: c_int) -> c_int {
    tun2socks::set_block_http3(enabled != 0);
    0
}

/// Read whether "block HTTP/3 (QUIC)" is currently enabled. Returns 1 if
/// enabled, 0 otherwise.
#[no_mangle]
pub extern "C" fn meow_tun_block_http3() -> c_int {
    c_int::from(tun2socks::block_http3())
}

/// Resident memory size of the FFI's containing process, in bytes. Same
/// number macOS jetsam compares against the 50 MiB PacketTunnel cap, so
/// Swift can poll this to chart the on-device RSS curve during a stress
/// run without depending on Instruments. Returns 0 on platforms where
/// the mach call isn't available (non-Apple targets).
#[no_mangle]
pub extern "C" fn meow_resident_bytes() -> u64 {
    rss::resident_bytes().unwrap_or(0)
}
