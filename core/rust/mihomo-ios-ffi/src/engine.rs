//! Embedded mihomo-rust engine. Owns the REST API task and holds the
//! `Tunnel` used directly (in-process) by `tun2socks` — there is no local
//! SOCKS listener; TCP flows hop Rust-to-Rust through a shared
//! `Arc<TunnelInner>` rather than through a loopback socket.
//!
//! DNS is delegated end-to-end to mihomo's resolver. The pinned `dns:` block
//! injected below puts the resolver in fake-IP mode with the FFI's chosen
//! CIDR (`28.0.0.0/8`) and no listening socket (`listen: ""`). The tun2socks
//! UDP/53 intercept hands every in-TUN DNS datagram straight to
//! `mihomo_dns::DnsServer::handle_query`, which both synthesises the fake-IP
//! answer and owns the reverse mapping that `mihomo_tunnel::pre_handle_metadata`
//! consults on the TCP/UDP dispatch path. The engine spawns no separate DNS
//! task and binds no DNS socket.
//!
//! Lifecycle: `start(config_path)` spawns the REST API on the shared tokio
//! runtime and keeps its `JoinHandle` in `EngineState`. `stop()` aborts that
//! task and *blocks* on it before returning — dropping the future drops the
//! `TcpListener` and releases the port synchronously, so a fast
//! `start → stop → start` cycle doesn't race the previous bind
//! (`EADDRINUSE`).
use anyhow::{Context, Result};
use dashmap::DashMap;
use mihomo_api::log_stream::{LogBroadcastLayer, LogMessage};
use mihomo_api::ApiServer;
use mihomo_config::{load_config, load_config_from_str, Config};
use mihomo_tunnel::{Statistics, Tunnel};
use parking_lot::{Mutex, RwLock};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Once, OnceLock};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{error, info};
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::prelude::*;

use crate::logging::LogForwardLayer;

struct EngineState {
    stats: Arc<Statistics>,
    tunnel: Tunnel,
    api_task: Option<JoinHandle<()>>,
}

fn slot() -> &'static Mutex<Option<EngineState>> {
    static S: OnceLock<Mutex<Option<EngineState>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

fn install_tls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Strip the shorthand listener ports and explicit `listeners:` array from a
/// raw config YAML. iOS dispatches TCP flows in-process via the netstack →
/// `mihomo_tunnel` Rust-to-Rust hop (no SOCKS loopback) and answers DNS
/// inline by handing every in-TUN UDP/53 datagram to
/// `mihomo_dns::DnsServer::handle_query` (no bound resolver port); there is
/// no loopback listener and no bound port. Upstream's `build_named_listeners`
/// (mihomo-config/src/lib.rs) hard-errors on duplicate ports (ADR-0002
/// Class A) — e.g. "port 7890 already used by listener 'mixed'" — so a
/// user YAML combining `mixed-port: 7890` with a listeners entry on the
/// same port would fail parse-time validation even though iOS never
/// actually binds either. This strip enforces the no-listener constraint
/// architecturally at the FFI boundary, regardless of YAML content.
///
/// Operates on a generic `serde_yaml::Value` rather than projecting through
/// `RawConfig`: the latter has no `#[serde(flatten)]` catch-all and no
/// `skip_serializing_if` on its Options, so a struct round-trip would
/// silently drop any top-level key it doesn't model (`tun:`, `profile:`,
/// `experimental:`, `global-client-fingerprint`, `unified-delay`, etc.)
/// and pollute the output with `key: null` for every unset Option.
fn strip_listener_fields(yaml: &str) -> Result<String> {
    let mut doc: serde_yaml::Value = serde_yaml::from_str(yaml).context("parsing config YAML")?;
    if let serde_yaml::Value::Mapping(m) = &mut doc {
        for key in [
            "port",
            "socks-port",
            "mixed-port",
            "tproxy-port",
            "listeners",
            // Drop the entire `sniffer:` block. mihomo's
            // `pre_handle_metadata` reverses each fake-IP destination back
            // to the qname recorded by the resolver before rule matching,
            // so SNI/ALPN sniffing is redundant — and when enabled it would
            // overwrite the resolver-derived hostname based on whatever the
            // sniffer parses out of the first TLS / HTTP record, which is a
            // regression versus the authoritative qname captured at DNS
            // resolution time. Strip at the FFI boundary so user
            // subscriptions can't re-enable it.
            "sniffer",
            // Drop any user-supplied `dns:` block. iOS pins its own resolver
            // configuration via `pinned_dns_block` below so the resolver is
            // always in fake-IP mode with the FFI's chosen CIDR and known-good
            // CN upstreams, regardless of subscription content.
            "dns",
        ] {
            m.remove(serde_yaml::Value::String(key.to_string()));
        }
        // Inject the pinned DNS config last so it always wins over any
        // residue we just removed.
        if let serde_yaml::Value::Mapping(dns) = pinned_dns_block() {
            m.insert(
                serde_yaml::Value::String("dns".into()),
                serde_yaml::Value::Mapping(dns),
            );
        }
    }
    serde_yaml::to_string(&doc).context("serializing stripped config YAML")
}

/// Pinned DNS block injected into every engine config. Configures mihomo's
/// resolver in fake-IP mode with the FFI's chosen CIDR; the tun2socks
/// UDP/53 intercept then hands every in-TUN datagram straight to
/// `mihomo_dns::DnsServer::handle_query`, so this block is the single source
/// of truth for synthesis, reverse mapping, AAAA / hosts / NXDOMAIN, and
/// upstream nameserver selection.
///
/// The nameserver set is restricted to CN-side resolvers because mihomo's
/// `query_pool` races every entry in parallel ("first response wins"), and
/// mixing a global anycast resolver into the same pool lets it win the race
/// from outside CN — returning the global / SG / HK PoP for split-horizon
/// hosts like xiaohongshu.com, which then misses the GEOIP-driven CN bypass
/// inside mihomo's rule engine.
///
///   * 119.29.29.29 (DNSPod / Tencent) — fast inside CN, also reachable
///     externally; primary for split-horizon hosts that need the CN view.
///   * 223.5.5.5    (Alibaba PublicDNS) — secondary CN-side nameserver.
///
/// If a global fallback is ever needed for sites the CN resolvers refuse to
/// answer, the right place to wire it is mihomo-rust's `fallback:` block
/// (which only runs when the primary pool yields nothing or the answer
/// trips `fallback-filter`), not the primary `nameserver:` pool.
///
/// `listen: ""` keeps mihomo from binding its own UDP/53 socket — the FFI
/// owns the in-TUN intercept and calls `DnsServer::handle_query` directly.
fn pinned_dns_block() -> serde_yaml::Value {
    let yaml = r#"
enable: true
listen: ""
enhanced-mode: fake-ip
fake-ip-range: 28.0.0.0/8
nameserver:
  - 119.29.29.29
  - 223.5.5.5
"#;
    serde_yaml::from_str(yaml).expect("pinned DNS YAML is a compile-time constant")
}

/// RAII handle that removes a file on drop. Used so the sibling
/// `effective-config.ios-stripped.yaml` we hand to `load_config` never
/// survives past the load call — including on `?` early-returns, panics,
/// and profile-swap failures.
struct TempFileGuard(PathBuf);

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Read `config_path`, strip listener fields, and hand a sibling
/// `effective-config.ios-stripped.yaml` to `load_config`. The sibling
/// placement is deliberate: `load_config` uses `path.parent()` as the
/// rule-/proxy-provider `cache_dir`, so colocating with the original
/// keeps rule-provider cache files in the AppGroup container. Using
/// `load_config_from_str` or `std::env::temp_dir()` would silently
/// disable that caching.
fn load_stripped_config(config_path: &str) -> Result<Config> {
    let original = std::fs::read_to_string(config_path)
        .with_context(|| format!("reading config from {config_path}"))?;
    let stripped = strip_listener_fields(&original)?;
    let stripped_path = PathBuf::from(format!("{config_path}.ios-stripped.yaml"));
    std::fs::write(&stripped_path, stripped)
        .with_context(|| format!("writing stripped config to {}", stripped_path.display()))?;
    let _guard = TempFileGuard(stripped_path.clone());
    let cfg =
        crate::get_runtime().block_on(load_config(stripped_path.to_str().expect("utf-8 path")))?;
    Ok(cfg)
}

/// Same strip as `load_stripped_config` but for in-memory YAML (editor
/// validation). No cache_dir involved, so we skip the temp-file dance.
///
/// Two safety hops vs the engine-start path:
///
/// 1. Strip `rule-providers:` in addition to listener fields. Upstream
///    `mihomo_config::rule_provider::load_providers` synchronously
///    `block_on`s its own `Runtime::new()`; calling that from inside any
///    other tokio runtime panics in `enter_runtime` ("Cannot start a
///    runtime from within a runtime"). Editor validation cares about
///    YAML grammar + proxy/rule shape, not whether provider URLs resolve,
///    so dropping the section is harmless.
///
/// 2. Drive `load_config_from_str` from `spawn_blocking` + `futures::executor`
///    rather than the FFI's shared `get_runtime()`. The spawn_blocking
///    hop lifts us off any tokio worker; `futures::executor::block_on`
///    is a non-tokio driver and therefore does not install an
///    `EnterGuard`. If any upstream callsite ever block_on's its own
///    runtime the way `load_providers` does, we won't nest.
fn load_stripped_config_from_str(yaml: &str) -> Result<Config> {
    let stripped = strip_for_validation(yaml)?;
    crate::get_runtime().block_on(async move {
        tokio::task::spawn_blocking(move || {
            futures::executor::block_on(load_config_from_str(&stripped))
                .context("load_config_from_str (validation)")
        })
        .await
        .map_err(|e| anyhow::anyhow!("validator join error: {e}"))?
    })
}

/// Editor-only variant of [`strip_listener_fields`]: also drops
/// `rule-providers:`. See `load_stripped_config_from_str` doc comment
/// for the nested-runtime rationale. The engine-start path keeps
/// rule-providers — the engine actually needs them at runtime, and on
/// that path `load_providers` runs against a non-nested context
/// (file-backed `load_config` uses a different load path).
fn strip_for_validation(yaml: &str) -> Result<String> {
    let listener_stripped = strip_listener_fields(yaml)?;
    let mut doc: serde_yaml::Value =
        serde_yaml::from_str(&listener_stripped).context("parsing stripped YAML for validation")?;
    if let serde_yaml::Value::Mapping(m) = &mut doc {
        m.remove(serde_yaml::Value::String("rule-providers".into()));
    }
    serde_yaml::to_string(&doc).context("serializing validation YAML")
}

/// Process-wide log broadcast channel. Registered into the tracing subscriber
/// on first `start()` and handed to every subsequent `ApiServer::new` —
/// tracing's global default can only be set once, so the channel (and the
/// registry that feeds it) outlive individual engine lifetimes.
fn log_broadcast_tx() -> &'static broadcast::Sender<LogMessage> {
    static TX: OnceLock<broadcast::Sender<LogMessage>> = OnceLock::new();
    TX.get_or_init(|| {
        let (tx, _rx) = broadcast::channel(128);
        tx
    })
}

/// Install the tracing subscriber once per process. Subsequent calls are
/// no-ops — re-invoking `set_global_default` after start/stop/start would
/// panic with `SetGlobalDefaultError`.
fn install_tracing_subscriber() {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        // INFO, not TRACE. serde emits per-`deserialize_any` / `deserialize_option`
        // spans at TRACE; under burst load (video streaming + simultaneous
        // `/configs` or `/providers` hits from the main app) this flooded the
        // broadcast channel with thousands of events per second. Each event is
        // processed synchronously on the emitting tokio worker via `on_event`,
        // starving the 2-worker runtime until TCP flow handling stalled. The
        // /logs WebSocket consumers never wanted serde trace spans anyway.
        let log_layer = LogBroadcastLayer {
            tx: log_broadcast_tx().clone(),
        }
        .with_filter(LevelFilter::INFO);
        // `try_init` returns Err if another subscriber beat us to the global
        // slot (unlikely in the FFI, but be defensive — panicking here would
        // abort the extension).
        let _ = tracing_subscriber::registry()
            .with(LogForwardLayer)
            .with(log_layer)
            .try_init();
    });
}

pub fn start(config_path: &str) -> Result<()> {
    if slot().lock().is_some() {
        return Ok(());
    }

    install_tls_provider();
    install_tracing_subscriber();

    // Strip listener shorthand + `listeners:` from the raw YAML before
    // load_config parses it — upstream's `build_named_listeners` rejects
    // duplicate ports (ADR-0002 Class A) even though iOS never binds any
    // of them. See `load_stripped_config` doc for the constraint rationale.
    let cfg = load_stripped_config(config_path)?;
    let raw_config = Arc::new(RwLock::new(cfg.raw.clone()));

    let tunnel = Tunnel::new(cfg.dns.resolver.clone());
    tunnel.set_mode(cfg.general.mode);
    tunnel.update_rules(cfg.rules);
    tunnel.update_proxies(cfg.proxies);
    let stats = tunnel.statistics().clone();

    // `ApiServer::new` grew from 5 to 9 parameters to serve the new
    // `/providers/*`, `/rules`, `/listeners`, and `/logs` routes. Build the
    // required shapes from the loaded Config.
    let proxy_providers = {
        let map: DashMap<_, _> = cfg.proxy_providers.into_iter().collect();
        Arc::new(map)
    };
    let rule_providers = Arc::new(RwLock::new(
        cfg.rule_providers.into_iter().collect::<HashMap<_, _>>(),
    ));
    let listeners = cfg.listeners.named.clone();
    let log_tx = log_broadcast_tx().clone();

    // No FFI-side fake-IP pool, no FFI-side CN-IP table, no resolver hand-off:
    // mihomo's own fake-IP pool (configured by `pinned_dns_block`) owns
    // synthesis + reverse mapping, and the tun2socks UDP/53 intercept fetches
    // the resolver lazily through `engine::tunnel()?.resolver()`.

    let api_task = cfg.api.external_controller.map(|addr| {
        let api_server = ApiServer::new(
            tunnel.clone(),
            addr,
            cfg.api.secret.clone(),
            config_path.to_string(),
            raw_config,
            log_tx,
            proxy_providers,
            rule_providers,
            listeners,
        );
        crate::get_runtime().spawn(async move {
            if let Err(e) = api_server.run().await {
                error!("API server error: {}", e);
            }
        })
    });

    info!("mihomo-rust engine running (in-process dispatch)");

    *slot().lock() = Some(EngineState {
        stats,
        tunnel,
        api_task,
    });
    Ok(())
}

pub fn stop() {
    // Take the state out before awaiting — we don't want to hold the
    // parking_lot mutex across the runtime `block_on`.
    let Some(state) = slot().lock().take() else {
        return;
    };

    // Aborting the task drops its future, which drops the TcpListener /
    // UdpSocket and releases the port. `block_on` waits for that drop to
    // actually happen before `stop()` returns — without it, a rapid
    // start → stop → start cycle observed `EADDRINUSE` on the REST bind.
    let runtime = crate::get_runtime();
    if let Some(h) = state.api_task {
        h.abort();
        let _ = runtime.block_on(h);
    }
    // DNS owns no background task — `DnsServer::handle_query` runs inline on
    // the tun2socks UDP/53 intercept path, so there's nothing to abort here.
    info!("mihomo-rust engine stopped");
}

pub fn is_running() -> bool {
    slot().lock().is_some()
}

pub fn traffic() -> (i64, i64) {
    slot()
        .lock()
        .as_ref()
        .map(|s| s.stats.snapshot())
        .unwrap_or((0, 0))
}

pub fn tunnel() -> Option<Tunnel> {
    slot().lock().as_ref().map(|s| s.tunnel.clone())
}

pub fn validate(yaml: &str) -> Result<()> {
    install_tls_provider();
    // Match start()'s strip behaviour so the editor doesn't surface
    // port-collision errors for fields iOS ignores anyway.
    let _ = load_stripped_config_from_str(yaml)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::strip_listener_fields;

    #[test]
    fn strip_removes_listener_keys_only() {
        let yaml = r#"
port: 7890
socks-port: 7891
mixed-port: 7892
tproxy-port: 7895
listeners:
  - name: mixed
    type: mixed
    port: 7890
sniffer:
  enable: true
  sniff:
    TLS:
      ports: [443]
mode: rule
log-level: info
"#;
        let out = strip_listener_fields(yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        let m = doc.as_mapping().unwrap();
        for k in [
            "port",
            "socks-port",
            "mixed-port",
            "tproxy-port",
            "listeners",
            "sniffer",
        ] {
            assert!(
                !m.contains_key(serde_yaml::Value::String(k.into())),
                "{k} should have been stripped",
            );
        }
        assert_eq!(m.get("mode").and_then(|v| v.as_str()), Some("rule"));
        assert_eq!(m.get("log-level").and_then(|v| v.as_str()), Some("info"));

        // Pinned DNS block must always be present after strip, with the
        // CN-side nameservers in order. The set is intentionally
        // CN-only — see `pinned_dns_block`'s doc comment on why a global
        // resolver (1.1.1.1 etc.) is *not* part of this pool.
        let dns = m
            .get(serde_yaml::Value::String("dns".into()))
            .and_then(|v| v.as_mapping())
            .expect("pinned dns block injected");
        let ns: Vec<&str> = dns
            .get(serde_yaml::Value::String("nameserver".into()))
            .and_then(|v| v.as_sequence())
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(ns, vec!["119.29.29.29", "223.5.5.5"]);
    }

    #[test]
    fn user_dns_is_replaced_by_pinned() {
        let yaml = r#"
dns:
  enable: true
  nameserver:
    - 8.8.8.8
    - 9.9.9.9
mode: rule
"#;
        let out = strip_listener_fields(yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        let dns = doc
            .as_mapping()
            .unwrap()
            .get(serde_yaml::Value::String("dns".into()))
            .and_then(|v| v.as_mapping())
            .unwrap();
        let ns: Vec<&str> = dns
            .get(serde_yaml::Value::String("nameserver".into()))
            .and_then(|v| v.as_sequence())
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(
            ns,
            vec!["119.29.29.29", "223.5.5.5"],
            "user nameservers must not survive the strip+inject"
        );
    }

    #[test]
    fn strip_preserves_unmodeled_top_level_keys() {
        // Fields RawConfig does not model. A RawConfig round-trip would
        // silently drop these; the Value-based strip must keep them.
        let yaml = r#"
mixed-port: 7890
tun:
  enable: true
  stack: gvisor
profile:
  store-selected: true
experimental:
  sniff-tls-sni: true
global-client-fingerprint: chrome
unified-delay: true
tcp-concurrent: true
find-process-mode: strict
proxies:
  - name: p1
    type: direct
"#;
        let out = strip_listener_fields(yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        let m = doc.as_mapping().unwrap();
        assert!(!m.contains_key(serde_yaml::Value::String("mixed-port".into())));
        for k in [
            "tun",
            "profile",
            "experimental",
            "global-client-fingerprint",
            "unified-delay",
            "tcp-concurrent",
            "find-process-mode",
            "proxies",
        ] {
            assert!(
                m.contains_key(serde_yaml::Value::String(k.into())),
                "{k} must survive the strip",
            );
        }
        let tun = m
            .get(serde_yaml::Value::String("tun".into()))
            .and_then(|v| v.as_mapping())
            .unwrap();
        assert_eq!(
            tun.get(serde_yaml::Value::String("stack".into()))
                .and_then(|v| v.as_str()),
            Some("gvisor"),
        );
    }

    #[test]
    fn strip_is_idempotent_on_clean_config() {
        let yaml = "mode: rule\nlog-level: info\n";
        let once = strip_listener_fields(yaml).expect("strip ok");
        let twice = strip_listener_fields(&once).expect("strip ok");
        assert_eq!(once, twice);
    }

    #[test]
    fn strip_for_validation_drops_rule_providers() {
        let yaml = r#"
mixed-port: 7890
rule-providers:
  reject:
    type: http
    behavior: domain
    url: https://example.test/reject.txt
    path: ./reject.txt
proxies:
  - name: p1
    type: direct
rules:
  - MATCH,p1
"#;
        let out = super::strip_for_validation(yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        let m = doc.as_mapping().unwrap();
        assert!(!m.contains_key(serde_yaml::Value::String("rule-providers".into())));
        assert!(m.contains_key(serde_yaml::Value::String("proxies".into())));
        assert!(m.contains_key(serde_yaml::Value::String("rules".into())));
    }

    /// Regression for the iOS 1.1.4 (2026051901) TestFlight crash:
    /// `meow_engine_validate_config` panicked in
    /// `tokio::runtime::context::runtime::enter_runtime` whenever the user's
    /// YAML carried `rule-providers:`. Verifies the validate FFI returns
    /// success (not panic) on a YAML that previously crashed.
    #[test]
    fn validate_does_not_panic_on_rule_providers() {
        let yaml = r#"
mixed-port: 7890
rule-providers:
  reject:
    type: http
    behavior: domain
    url: https://example.test/reject.txt
    path: ./reject.txt
    interval: 86400
proxies:
  - name: p1
    type: direct
rules:
  - MATCH,p1
"#;
        super::validate(yaml).expect("validate must not panic on rule-providers");
    }

    /// Regression for the same crash, exercised through the C ABI surface
    /// the iOS app actually calls (`meow_engine_validate_config`). Confirms
    /// the rc=0 contract holds end-to-end for a config with rule-providers.
    #[test]
    fn ffi_validate_returns_zero_on_rule_providers() {
        use std::ffi::CString;
        let yaml = r#"
mixed-port: 7890
rule-providers:
  reject:
    type: http
    behavior: domain
    url: https://example.test/reject.txt
    path: ./reject.txt
    interval: 86400
proxies:
  - name: p1
    type: direct
rules:
  - MATCH,p1
"#;
        let cstr = CString::new(yaml).unwrap();
        let rc = unsafe {
            crate::meow_engine_validate_config(cstr.as_ptr(), yaml.len() as std::os::raw::c_int)
        };
        assert_eq!(rc, 0, "FFI validate must succeed on rule-providers YAML");
    }
}

#[cfg(test)]
mod config_parse_tests {
    //! Regression test for the feature-flag fix that re-enabled `ss` / `trojan`
    //! on mihomo-config. If `mihomo-config` is ever pulled with
    //! `default-features = false` and those feature strings missing again,
    //! every `type: ss` proxy falls through `parse_proxy`'s catch-all
    //! `_ => Err("unsupported proxy type: ss")` → warn-skip → groups that
    //! reference those proxies lose all valid members → dropped in lenient
    //! fallback. This test catches that regression at compile-time for the
    //! feature flip and at runtime for parser drift.
    const FIXTURE: &str = include_str!("../tests/fixtures/subscription_ss_like.yaml");

    #[test]
    fn fixture_parses_with_all_proxies_and_groups() {
        // Strip listener keys via the production helper (value-based) so the
        // regression test also exercises the strip path.
        let stripped = super::strip_listener_fields(FIXTURE).expect("strip ok");
        let rt = tokio::runtime::Runtime::new().expect("tokio rt");
        let cfg = rt
            .block_on(mihomo_config::load_config_from_str(&stripped))
            .expect("load_config_from_str on the fixture should succeed");

        let (groups, leaves): (Vec<_>, Vec<_>) =
            cfg.proxies.values().partition(|p| p.members().is_some());

        // Fixture has 141 ss proxies + 22 groups. Expected runtime totals:
        //   leaves = 141 ss + 3 built-ins (DIRECT, REJECT, REJECT-DROP) = 144
        //   groups = 22 user-defined (Proxies, 20 categories, Direct, Final)
        assert_eq!(
            leaves.len(),
            144,
            "expected 141 ss proxies + 3 built-ins; if this drops to 3, \
             mihomo-config was built without the `ss` feature — see commit \
             enabling default features on the mihomo-config dep",
        );
        assert_eq!(groups.len(), 22, "all 22 user-defined groups must resolve");
    }
}
