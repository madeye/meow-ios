//! Embedded meow-rs engine. Owns the REST API task plus the local mixed and
//! DNS listeners that `tun2socks` dials through loopback.
//!
//! DNS is delegated end-to-end to meow's resolver. The pinned `dns:` block from
//! `meow_patch_config` puts the resolver in fake-IP mode with the FFI's chosen
//! CIDR (`28.0.0.0/8`) and a local DNS listen socket. The tun2socks UDP/53
//! path sends non-blocked DNS queries to that listener, so synthesis and
//! fake-IP reverse mapping stay owned by meow-dns.
//!
//! Lifecycle: `start(config_path)` spawns the REST API on the meow-engine
//! tokio runtime and keeps its `JoinHandle` in `EngineState`. `stop()` aborts
//! that task and *blocks* on it before returning — dropping the future drops the
//! `TcpListener` and releases the port synchronously, so a fast
//! `start → stop → start` cycle doesn't race the previous bind
//! (`EADDRINUSE`).
use anyhow::{Context, Result};
use dashmap::DashMap;
use meow_api::log_stream::{LogBroadcastLayer, LogMessage};
use meow_api::ApiServer;
use meow_config::{load_config, load_config_from_str, Config};
use meow_dns::DnsServer;
use meow_listener::{MixedListener, SnifferRuntime};
use meow_tunnel::{Statistics, Tunnel};
use parking_lot::{Mutex, RwLock};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Once, OnceLock};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{error, info};
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::prelude::*;

use crate::logging::LogForwardLayer;

/// Connection cap applied to the loopback SOCKS5/mixed listener that lwIP
/// dials. The meow-config default is `0` (unlimited); on iOS we bound it so a
/// burst of new flows can't spawn unbounded per-connection handler state on
/// the engine runtime. Sized to match `tun2socks::TCP_ACCEPT_CAP_DEFAULT`
/// (256) — the tun2socks side already caps in-flight flows there, so the
/// listener will rarely hit this, but it backstops the case where a client
/// other than our own tun2socks dials the loopback port. An explicit
/// `max-connections` in the config still wins.
const LOOPBACK_LISTENER_MAX_CONNECTIONS: usize = 256;

fn loopback_addr(port: u16) -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)
}

fn bind_socket_addr(listen: &str, port: u16) -> Result<SocketAddr> {
    let ip: IpAddr = listen
        .parse()
        .map_err(|e| anyhow::anyhow!("invalid bind address '{listen}': {e}"))?;
    Ok(SocketAddr::new(ip, port))
}

struct EngineState {
    stats: Arc<Statistics>,
    tunnel: Tunnel,
    mixed_dial_addr: Option<SocketAddr>,
    dns_dial_addr: Option<SocketAddr>,
    api_task: Option<JoinHandle<()>>,
    listener_tasks: Vec<JoinHandle<()>>,
}

fn slot() -> &'static Mutex<Option<EngineState>> {
    static S: OnceLock<Mutex<Option<EngineState>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

fn install_tls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Normalize the effective YAML before `load_config`: iOS owns exactly one
/// mixed listener (`mixed-port`) and exactly one DNS listener (`dns.listen`).
/// Drop other listener shorthands / explicit listener arrays so subscriptions
/// cannot create duplicate ports or unexpected inbound sockets.
///
/// Operates on a generic `serde_yaml::Value` rather than projecting through
/// `RawConfig`: the latter has no `#[serde(flatten)]` catch-all and no
/// `skip_serializing_if` on its Options, so a struct round-trip would
/// silently drop any top-level key it doesn't model (`tun:`, `profile:`,
/// `experimental:`, `global-client-fingerprint`, `unified-delay`, etc.)
/// and pollute the output with `key: null` for every unset Option.
fn prepare_ios_config(yaml: &str) -> Result<String> {
    let mut doc: serde_yaml::Value = serde_yaml::from_str(yaml).context("parsing config YAML")?;
    if let serde_yaml::Value::Mapping(m) = &mut doc {
        for key in [
            "port",
            "socks-port",
            "tproxy-port",
            "listeners",
            // Drop the entire `sniffer:` block. meow's
            // `pre_handle_metadata` reverses each fake-IP destination back
            // to the qname recorded by the resolver before rule matching,
            // so SNI/ALPN sniffing is redundant — and when enabled it would
            // overwrite the resolver-derived hostname based on whatever the
            // sniffer parses out of the first TLS / HTTP record, which is a
            // regression versus the authoritative qname captured at DNS
            // resolution time. Strip at the FFI boundary so user
            // subscriptions can't re-enable it.
            "sniffer",
        ] {
            m.remove(serde_yaml::Value::String(key.to_string()));
        }
    }
    serde_yaml::to_string(&doc).context("serializing stripped config YAML")
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
    let stripped = prepare_ios_config(&original)?;
    let stripped_path = PathBuf::from(format!("{config_path}.ios-stripped.yaml"));
    std::fs::write(&stripped_path, stripped)
        .with_context(|| format!("writing stripped config to {}", stripped_path.display()))?;
    let _guard = TempFileGuard(stripped_path.clone());
    let cfg = crate::get_engine_runtime()
        .block_on(load_config(stripped_path.to_str().expect("utf-8 path")))?;
    Ok(cfg)
}

/// Same strip as `load_stripped_config` but for in-memory YAML (editor
/// validation). No cache_dir involved, so we skip the temp-file dance.
///
/// Two safety hops vs the engine-start path:
///
/// 1. Strip `rule-providers:` in addition to listener fields. Upstream
///    `meow_config::rule_provider::load_providers` synchronously
///    `block_on`s its own `Runtime::new()`; calling that from inside any
///    other tokio runtime panics in `enter_runtime` ("Cannot start a
///    runtime from within a runtime"). Editor validation cares about
///    YAML grammar + proxy/rule shape, not whether provider URLs resolve,
///    so dropping the section is harmless.
///
/// 2. Drive `load_config_from_str` from `spawn_blocking` + `futures::executor`
///    rather than directly nesting on the FFI's meow-engine runtime. The spawn_blocking
///    hop lifts us off any tokio worker; `futures::executor::block_on`
///    is a non-tokio driver and therefore does not install an
///    `EnterGuard`. If any upstream callsite ever block_on's its own
///    runtime the way `load_providers` does, we won't nest.
fn load_stripped_config_from_str(yaml: &str) -> Result<Config> {
    let stripped = strip_for_validation(yaml)?;
    crate::get_engine_runtime().block_on(async move {
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
    let listener_stripped = prepare_ios_config(yaml)?;
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
        // Use `set_global_default` directly instead of
        // `SubscriberInitExt::try_init`: the latter has a `tracing-log` side
        // effect that installs `tracing_log::LogTracer` as the global
        // `log::Logger`. Combined with our `LogForwardLayer` (tracing → log
        // bridge for oslog), that creates a tracing → log → LogTracer →
        // tracing cycle that blows the stack on the first event. We want
        // exactly one direction: tracing → log. The `log` global stays
        // owned by `oslog::OsLogger` (installed in `meow_core_init`).
        // Always-on DEBUG ring teed to <app-group>/logs/meow-tunnel.log so the
        // in-app log export can include the tunnel's own output (the engine and
        // NE host run in a different process than the app, whose OSLogStore can
        // only read its own PID). `Option<Layer>` is itself a `Layer`, so this
        // is a no-op when no home dir is set yet or the file won't open.
        let subscriber = tracing_subscriber::registry()
            .with(LogForwardLayer)
            .with(log_layer)
            .with(crate::file_log::layer());
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

pub fn start(config_path: &str) -> Result<()> {
    if slot().lock().is_some() {
        return Ok(());
    }

    install_tls_provider();
    install_tracing_subscriber();

    let cfg = load_stripped_config(config_path)?;
    let raw_config = Arc::new(RwLock::new(cfg.raw.clone()));

    let resolver = cfg.dns.resolver.clone();

    // Route proxy-upstream hostname resolution through meow-dns instead of
    // libc `getaddrinfo`. On the NE, `getaddrinfo` runs one blocking-pool
    // thread per lookup and re-resolves on every dial, so a wake-from-sleep
    // burst of flows to a single upstream stampedes the pool and can wedge the
    // 2-worker engine runtime (data path + REST API both freeze). The meow-dns
    // resolver resolves async, coalesces concurrent lookups, and caches —
    // collapsing the burst to one lookup. `resolve_ip` returns real addresses
    // (fake-IP synthesis lives only in the DNS-server `lookup_ipv4/6` path), so
    // the upstream never resolves to a 28.x fake IP. Android installs the same
    // hook plus a `SocketProtector` via its JNI bridge; iOS needs only the hook
    // (the NE process's own sockets already bypass its tunnel).
    meow_common::set_host_resolver(Arc::new(meow_dns::ResolverHostHook::new(resolver.clone())));

    let tunnel = Tunnel::new(resolver.clone());
    tunnel.set_mode(cfg.general.mode);
    tunnel.update_rules(cfg.rules);
    tunnel.update_proxies(cfg.proxies);

    // Start the tunnel's background tasks — currently just the UDP NAT
    // sweeper, which evicts sessions idle > DEFAULT_UDP_IDLE (60 s) every
    // DEFAULT_SWEEP_INTERVAL (15 s). Without this call the `nat_table` (and
    // the `reply_readers` set + detached reader tasks the FFI keys off it)
    // grows monotonically under UDP flow churn: every new 5-tuple inserts an
    // `Arc<UdpSession>` that is only removed on a reader-task exit that a
    // quiet session (one-shot DNS, abandoned QUIC, dead upstream) never
    // reaches. Over hours that slow growth crosses the ~50 MB NE jetsam cap
    // and the PacketTunnel is killed. `meow-app` calls this after building
    // its tunnel; the FFI must too. Idempotent — invoked once per engine.
    //
    // `start()` runs on the main thread, OUTSIDE the tokio runtime, and
    // `spawn_background_tasks` uses a bare `tokio::spawn` (unlike the
    // `get_engine_runtime().spawn(...)` callsites below, which carry their own
    // handle). Enter the runtime context for the call so the sweeper task
    // lands on the meow-engine runtime instead of panicking with "no reactor
    // running". The guard only needs to outlive the spawn.
    {
        let _enter = crate::get_engine_runtime().enter();
        tunnel.spawn_background_tasks();
    }

    let stats = tunnel.statistics().clone();

    // No `meow_app::geodata_fetch::run_on_startup` spawn here: the iOS app
    // bundles Country.mmdb, GeoLite2-ASN.mmdb, and geosite.mrs in
    // App/Resources/GeoData and `GeoAssetStager` stages them into
    // `AppGroup.meowConfigDir` at app launch, so every DB the rule loader
    // and resolver want is already on disk before the engine starts. The
    // upstream fetcher checks `meow_config::default_geosite_path()`
    // (`geosite.dat`) — which never exists in our layout, since we ship
    // `geosite.mrs` — and would otherwise spawn `reqwest`/`hyper`/
    // `tokio-rustls`/`aws-lc-rs` plus buffer a multi-MB download body in
    // process, blowing past the 50 MB NE jetsam cap within ~0.6 s of
    // launch (per-process-limit kill, observed via `idevicesyslog`).
    //
    // If a future build ever stops bundling one of the DBs, the FFI must
    // re-introduce a fetch — but in a memory-bounded form (streamed to
    // disk, no full-body buffer) suitable for the NE budget.

    let mut listener_tasks = Vec::new();
    let mixed_dial_addr = cfg.listeners.mixed_port.map(loopback_addr);
    let dns_dial_addr = cfg.dns.listen_addr.map(|addr| loopback_addr(addr.port()));

    if let Some(listen_addr) = cfg.dns.listen_addr {
        let dns_server = DnsServer::new(resolver.clone(), listen_addr);
        listener_tasks.push(crate::get_engine_runtime().spawn(async move {
            if let Err(e) = dns_server.run().await {
                error!("DNS server error: {}", e);
            }
        }));
    }

    let sniffer_runtime = Arc::new(SnifferRuntime::new(cfg.sniffer.clone()));
    let auth = cfg.auth.clone();
    for nl in &cfg.listeners.named {
        let addr = bind_socket_addr(&nl.listen, nl.port)
            .with_context(|| format!("listener '{}'", nl.name))?;
        match nl.listener_type {
            meow_config::ListenerType::Mixed
            | meow_config::ListenerType::Http
            | meow_config::ListenerType::Socks5 => {
                // Config default is 0 (unlimited); apply the iOS loopback cap
                // unless the config set an explicit per-listener/global value.
                let max_connections = if nl.max_connections == 0 {
                    LOOPBACK_LISTENER_MAX_CONNECTIONS
                } else {
                    nl.max_connections
                };
                let listener = MixedListener::new(tunnel.clone(), addr, nl.name.clone())
                    .with_sniffer(sniffer_runtime.clone())
                    .with_auth(auth.clone())
                    .with_max_connections(max_connections);
                listener_tasks.push(crate::get_engine_runtime().spawn(async move {
                    if let Err(e) = listener.run().await {
                        error!("Mixed listener error: {}", e);
                    }
                }));
            }
            meow_config::ListenerType::TProxy => {
                // iOS deliberately does not start transparent-proxy listeners.
            }
        }
    }

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
    // meow's own fake-IP pool owns synthesis + reverse mapping behind the DNS
    // listener that tun2socks dials.

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
        // Spawn on the dedicated API runtime, NOT the engine runtime: a burst
        // of REST calls (e.g. the host app's per-stage `/proxies` + `/configs`
        // wave) must not be able to starve the data-path relay / DNS tasks that
        // share the engine workers. See `get_api_runtime`.
        crate::get_api_runtime().spawn(async move {
            if let Err(e) = api_server.run().await {
                error!("API server error: {}", e);
            }
        })
    });

    info!(
        "meow-rs engine running (mixed={:?}, dns={:?})",
        mixed_dial_addr, dns_dial_addr
    );

    *slot().lock() = Some(EngineState {
        stats,
        tunnel,
        mixed_dial_addr,
        dns_dial_addr,
        api_task,
        listener_tasks,
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
    let runtime = crate::get_engine_runtime();
    // The API task lives on its own runtime (see `get_api_runtime`), so its
    // abort/join must be driven by that runtime — `block_on` only awaits tasks
    // belonging to the runtime it's called on.
    if let Some(h) = state.api_task {
        h.abort();
        let _ = crate::get_api_runtime().block_on(h);
    }
    for h in state.listener_tasks {
        h.abort();
        let _ = runtime.block_on(h);
    }
    info!("meow-rs engine stopped");
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

pub fn mixed_dial_addr() -> Option<SocketAddr> {
    slot().lock().as_ref().and_then(|s| s.mixed_dial_addr)
}

pub fn dns_dial_addr() -> Option<SocketAddr> {
    slot().lock().as_ref().and_then(|s| s.dns_dial_addr)
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
    use super::{load_stripped_config_from_str, prepare_ios_config};
    use std::net::SocketAddr;

    #[test]
    fn prepare_removes_extra_listener_keys_only() {
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
        let out = prepare_ios_config(yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        let m = doc.as_mapping().unwrap();
        for k in ["port", "socks-port", "tproxy-port", "listeners", "sniffer"] {
            assert!(
                !m.contains_key(serde_yaml::Value::String(k.into())),
                "{k} should have been stripped",
            );
        }
        assert_eq!(m.get("mixed-port").and_then(|v| v.as_i64()), Some(7892));
        assert_eq!(m.get("mode").and_then(|v| v.as_str()), Some("rule"));
        assert_eq!(m.get("log-level").and_then(|v| v.as_str()), Some("info"));
    }

    #[test]
    fn user_dns_survives_runtime_prepare() {
        let yaml = r#"
dns:
  enable: true
  nameserver:
    - 8.8.8.8
    - 9.9.9.9
mode: rule
"#;
        let out = prepare_ios_config(yaml).expect("strip ok");
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
            vec!["8.8.8.8", "9.9.9.9"],
            "prepare_ios_config must not rewrite dns; meow_patch_config owns pinning"
        );
    }

    #[test]
    fn stripped_config_loads_mixed_and_dns_listeners() {
        let yaml = r#"
mixed-port: 23456
allow-lan: true
bind-address: 0.0.0.0
dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 28.0.0.0/8
  nameserver:
    - 119.29.29.29
rules:
  - MATCH,DIRECT
"#;
        let cfg = load_stripped_config_from_str(yaml).expect("config loads");
        assert_eq!(cfg.listeners.mixed_port, Some(23456));
        let mixed = cfg
            .listeners
            .named
            .iter()
            .find(|listener| listener.name == "mixed")
            .expect("mixed listener is auto-created from mixed-port");
        assert_eq!(mixed.listen, "0.0.0.0");
        assert_eq!(mixed.port, 23456);
        assert_eq!(
            cfg.dns.listen_addr,
            Some("0.0.0.0:1053".parse::<SocketAddr>().unwrap())
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
        let out = prepare_ios_config(yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        let m = doc.as_mapping().unwrap();
        assert!(m.contains_key(serde_yaml::Value::String("mixed-port".into())));
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
        let once = prepare_ios_config(yaml).expect("strip ok");
        let twice = prepare_ios_config(&once).expect("strip ok");
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
    //! on meow-config. If `meow-config` is ever pulled with
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
        let stripped = super::prepare_ios_config(FIXTURE).expect("strip ok");
        let rt = tokio::runtime::Runtime::new().expect("tokio rt");
        let cfg = rt
            .block_on(meow_config::load_config_from_str(&stripped))
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
             meow-config was built without the `ss` feature — see commit \
             enabling default features on the meow-config dep",
        );
        assert_eq!(groups.len(), 22, "all 22 user-defined groups must resolve");
    }
}
