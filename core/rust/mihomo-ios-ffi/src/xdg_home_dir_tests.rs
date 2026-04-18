//! Regression test for `meow_core_set_home_dir` wiring `$XDG_CONFIG_HOME` so
//! `mihomo-config`'s `default_geoip_path()` resolves to the caller-supplied
//! directory (iOS app-group container in production).
//!
//! Lives as a `#[cfg(test)]` module in `src/` rather than under `tests/` because
//! adding `rlib` to the crate-type (needed for integration tests against a
//! pure staticlib) would inflate the per-arch staticlib from ~16MB to ~88MB.
//! Kept in-crate to preserve the staticlib-only build. All tested FFI symbols
//! are `pub`, so Rust-side invocation exercises the exact same code path as
//! a cross-crate link would.
//!
//! Three layered assertions:
//! 1. Direct env wire-up — after calling `meow_core_set_home_dir(tmp)`,
//!    `env::var("XDG_CONFIG_HOME")` returns `tmp`.
//! 2. Engine load path — `meow_engine_validate_config` on a YAML containing a
//!    `GEOIP` rule succeeds only if the MMDB at
//!    `$XDG_CONFIG_HOME/mihomo/Country.mmdb` was actually read. Without the
//!    env-var write this falls back to `$HOME/.config/mihomo/…` and fails.
//! 3. Probe-IP proof — open the MMDB directly from the env-derived path and
//!    resolve `214.78.120.1 → US` per MaxMind's documented test data.

use std::ffi::{CStr, CString};
use std::os::raw::c_int;

use crate::{meow_core_last_error, meow_core_set_home_dir, meow_engine_validate_config};

const FIXTURE_MMDB: &[u8] = include_bytes!("../tests/fixtures/GeoIP2-Country-Test.mmdb");

const YAML_WITH_GEOIP_RULE: &str = "\
mode: rule
rules:
  - GEOIP,US,DIRECT
  - MATCH,DIRECT
";

#[test]
fn set_home_dir_wires_xdg_config_home_into_geoip_load_path() {
    let tmp = tempfile::tempdir().expect("create tmp dir");
    let mihomo_dir = tmp.path().join("mihomo");
    std::fs::create_dir_all(&mihomo_dir).expect("mkdir mihomo/");
    std::fs::write(mihomo_dir.join("Country.mmdb"), FIXTURE_MMDB)
        .expect("stage fixture Country.mmdb");

    let tmp_path = tmp
        .path()
        .to_str()
        .expect("tmp path is utf-8")
        .to_owned();
    let dir_cstr = CString::new(tmp_path.as_str()).expect("tmp path has no NUL");
    unsafe { meow_core_set_home_dir(dir_cstr.as_ptr()) };

    // (1) Direct env wire-up.
    assert_eq!(
        std::env::var("XDG_CONFIG_HOME").ok().as_deref(),
        Some(tmp_path.as_str()),
        "meow_core_set_home_dir must export XDG_CONFIG_HOME"
    );

    // (2) Engine load path — validate a YAML with a GEOIP rule, which forces
    //     mihomo-config to read `default_geoip_path()` = `$XDG_CONFIG_HOME/mihomo/Country.mmdb`.
    let yaml_cstr = CString::new(YAML_WITH_GEOIP_RULE).unwrap();
    let rc = unsafe {
        meow_engine_validate_config(
            yaml_cstr.as_ptr(),
            YAML_WITH_GEOIP_RULE.len() as c_int,
        )
    };
    if rc != 0 {
        let err_ptr = meow_core_last_error();
        let err = if err_ptr.is_null() {
            "<null>".to_string()
        } else {
            unsafe { CStr::from_ptr(err_ptr) }
                .to_string_lossy()
                .into_owned()
        };
        panic!(
            "meow_engine_validate_config returned rc={} — XDG_CONFIG_HOME wire-up \
             did not reach default_geoip_path(). last_error: {}",
            rc, err
        );
    }

    // (3) Probe-IP proof — open the MMDB via the env-derived path and look up
    //     a documented synthetic IP from MaxMind's test data.
    let probe_path = std::path::PathBuf::from(
        std::env::var_os("XDG_CONFIG_HOME").expect("XDG_CONFIG_HOME still set"),
    )
    .join("mihomo")
    .join("Country.mmdb");
    let reader = maxminddb::Reader::open_readfile(&probe_path)
        .expect("open fixture MMDB via env-derived path");
    let probe_ip: std::net::IpAddr = "214.78.120.1".parse().unwrap();
    let lookup = reader
        .lookup(probe_ip)
        .expect("lookup 214.78.120.1 succeeds");
    let record: maxminddb::geoip2::Country = lookup
        .decode()
        .expect("decode Country record")
        .expect("214.78.120.1 has a documented entry in the fixture");
    let iso = record
        .country
        .iso_code
        .expect("country iso_code present");
    assert_eq!(
        iso, "US",
        "214.78.120.1 should resolve to US per MaxMind's documented test data"
    );
}
