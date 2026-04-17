// Generated stub — overwritten by `cbindgen` during `scripts/build-rust.sh`.
// Committed so Swift can import these symbols before the Rust library is
// first built. Keep in sync with core/rust/mihomo-ios-ffi/src/lib.rs.
#pragma once
#ifndef MIHOMO_IOS_FFI_H
#define MIHOMO_IOS_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize logging. Safe to call more than once.
void meow_tun_init(void);

/// Set the directory containing the active profile's config.yaml. Pass NULL
/// or an empty string to fall back to built-in DoH servers.
void meow_tun_set_home_dir(const char *dir);

/// Start the mihomo-rust engine using the YAML at `config_path`. Idempotent.
/// Returns 0 on success, -1 on error.
int meow_engine_start(const char *config_path);

/// Stop the mihomo-rust engine. Idempotent.
void meow_engine_stop(void);

/// Validate a Clash YAML config. Returns 0 if it parses, -1 otherwise.
int meow_engine_validate_config(const char *yaml, int len);

/// Write the engine's cumulative upload / download byte counters to the
/// caller-provided slots. NULL pointers are skipped.
void meow_engine_traffic(int64_t *out_upload, int64_t *out_download);

/// Start tun2socks on `fd`, relaying TCP via SOCKS5 127.0.0.1:socks_port and
/// UDP DNS via DoH through the same proxy. Returns 0 on success, -1 on error.
int meow_tun_start(int fd, int socks_port, int dns_port);

/// Stop the tunnel. Idempotent.
void meow_tun_stop(void);

/// Last error message for the calling thread. Valid until the next error.
const char *meow_tun_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* MIHOMO_IOS_FFI_H */
