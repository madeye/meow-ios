// Hand-written stub — overwritten by `cbindgen` during `scripts/build-rust.sh`.
// Committed so Swift can import these symbols before the Rust library is
// first built. Keep in sync with core/rust/mihomo-ios-ffi/src/lib.rs.
#pragma once
#ifndef MIHOMO_CORE_H
#define MIHOMO_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Lifecycle / logging (shared surface — link into both app and extension)
// ---------------------------------------------------------------------------

/// Initialize os_log bridge. Safe to call more than once.
void meow_core_init(void);

/// Set the app-group container path where config.yaml and cache files live.
/// `dir` may be NULL or empty.
void meow_core_set_home_dir(const char *dir);

/// Last error message for the calling thread. Valid until the next error is
/// set on the same thread — copy immediately if retention is needed.
const char *meow_core_last_error(void);

// ---------------------------------------------------------------------------
// Engine (mihomo-rust) — lifecycle + config
// ---------------------------------------------------------------------------

/// Start the mihomo-rust engine using the YAML at `config_path`. Idempotent.
/// Returns 0 on success, -1 on error (inspect `meow_core_last_error`).
int meow_engine_start(const char *config_path);

/// Stop the mihomo-rust engine. Idempotent.
void meow_engine_stop(void);

/// Returns 1 if the engine is running, 0 otherwise.
int meow_engine_is_running(void);

/// Validate a Clash YAML config. Returns 0 on success, -1 on error.
int meow_engine_validate_config(const char *yaml, int len);

/// Write cumulative upload / download byte counters into the caller-provided
/// slots. NULL pointers are skipped. Safe to call before engine start.
void meow_engine_traffic(int64_t *out_upload, int64_t *out_download);

// ---------------------------------------------------------------------------
// Subscription conversion
// ---------------------------------------------------------------------------

/// Convert a subscription body (Clash YAML, or base64-wrapped / plain v2rayN
/// URI list) to Clash YAML. Writes NUL-terminated UTF-8 into `out`/`out_cap`.
/// Returns the total bytes needed (not counting NUL); if the return exceeds
/// `out_cap`, the output was truncated — allocate `ret + 1` and retry.
/// Returns -1 on error (inspect `meow_core_last_error`).
int meow_engine_convert_subscription(const char *body, int len,
                                     char *out, int out_cap);

// ---------------------------------------------------------------------------
// Diagnostics (engine must be running for proxy/DNS diagnostics)
// ---------------------------------------------------------------------------

/// Measure direct TCP connect latency to `host:port`. Writes elapsed ms into
/// `out_ms`; returns 0 on success, -1 on error.
int meow_engine_test_direct_tcp(const char *host, int port,
                                int timeout_ms, int64_t *out_ms);

/// HTTP reachability via the engine's default (direct) adapter. Writes the
/// HTTP status into `out_status` and elapsed ms into `out_ms`; returns 0 on
/// success, -1 on error.
int meow_engine_test_proxy_http(const char *url, int timeout_ms,
                                int *out_status, int64_t *out_ms);

/// Resolve `host` via the engine resolver. Writes comma-separated IPs into
/// `out`/`out_cap` (same truncation rules as `meow_engine_convert_subscription`).
int meow_engine_test_dns(const char *host, int timeout_ms,
                         char *out, int out_cap);

// ---------------------------------------------------------------------------
// tun2socks (NEPacketTunnelFlow bridge) — dispatches in-process into engine
// ---------------------------------------------------------------------------

/// Start tun2socks on `fd`. `socks_port` / `dns_port` are reserved for API
/// compatibility; the in-process dispatcher ignores both. Returns 0 on
/// success, -1 on error.
int meow_tun_start(int fd, int socks_port, int dns_port);

/// Stop the tunnel. Idempotent.
void meow_tun_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* MIHOMO_CORE_H */
