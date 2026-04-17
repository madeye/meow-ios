// Generated stub — overwritten by `cbindgen` during `scripts/build-rust.sh`.
// Committed so Swift can import these symbols before the Rust library is
// first built. Keep in sync with core/rust/mihomo-ios-ffi/src/lib.rs.
#pragma once
#ifndef MIHOMO_IOS_FFI_H
#define MIHOMO_IOS_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize logging. Safe to call more than once.
void meow_tun_init(void);

/// Set the directory containing the active profile's config.yaml. Pass NULL
/// or an empty string to fall back to built-in DoH servers.
void meow_tun_set_home_dir(const char *dir);

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
