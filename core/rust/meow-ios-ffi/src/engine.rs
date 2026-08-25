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
use meow_config::raw::RawConfig;
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
    /// Shared with the REST `ApiServer` (it receives a clone of this Arc) so
    /// a hot-reload can refresh what `GET /configs` reports and what a later
    /// REST `PUT /configs` diffs against.
    raw_config: Arc<RwLock<RawConfig>>,
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
/// cannot create duplicate ports or unexpected inbound sockets. Also inject
/// the iOS default `tcp-connect-timeout` (bounded DIRECT dial) when the
/// config doesn't set one — see the inline comment for rationale.
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
        for key in ["port", "socks-port", "tproxy-port", "listeners"] {
            m.remove(serde_yaml::Value::String(key.to_string()));
        }
        // Bound the built-in DIRECT adapter's `TcpStream::connect`. iOS
        // scoped-routing / reachability-cache transients can leave a direct
        // connect hanging indefinitely (see
        // docs/INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md);
        // without a bound the flow is reaped only by the 600 s idle
        // sweeper. 10 s: safely above cold cellular handshakes against
        // distant CN PoPs (~5-8 s observed) and below Mobile Safari's
        // ~12 s request-timeout floor, so the app's own retry loop kicks
        // in. Injected only when the user's config doesn't set it, so a
        // subscription/user override wins.
        let key = serde_yaml::Value::String("tcp-connect-timeout".to_string());
        if !m.contains_key(&key) {
            m.insert(key, serde_yaml::Value::Number(10.into()));
        }
        contain_provider_paths(m);
    }
    serde_yaml::to_string(&doc).context("serializing stripped config YAML")
}

/// Rewrite `rule-providers[*].path` / `proxy-providers[*].path` values that
/// would escape the provider cache directory into a contained
/// `./<basename>`.
///
/// meow-rs gained a `safe_path` containment guard (upstream #429): a provider
/// `path:` that is absolute, or that lexically escapes the cache dir via
/// `..`, is now a hard error out of `load_config` — which on iOS means
/// `meow_engine_start` fails and the tunnel never comes up. That guard is
/// correct (it closed an arbitrary-file-write), but it is a breaking change
/// for a very common real-world config: a subscription or profile exported
/// from a desktop client carries paths like
/// `/Users/me/.config/meow/ruleset/cn.yaml`.
///
/// Rejecting those on iOS buys nothing. The App Group container is the only
/// writable location in the sandbox, so a desktop absolute path could never
/// have resolved here regardless — it is dead information, not user intent.
/// Normalizing it to the basename inside the cache dir preserves the
/// provider's function and keeps upstream's containment guarantee intact
/// (we only ever write a contained relative path back).
///
/// Contained relative paths are left untouched, so configs authored for iOS
/// keep their exact on-disk layout, subdirectories included.
fn contain_provider_paths(root: &mut serde_yaml::Mapping) {
    for section in ["rule-providers", "proxy-providers"] {
        let Some(serde_yaml::Value::Mapping(providers)) =
            root.get_mut(serde_yaml::Value::String(section.to_string()))
        else {
            continue;
        };
        for (name, entry) in providers.iter_mut() {
            let Some(entry) = entry.as_mapping_mut() else {
                continue;
            };
            let path_key = serde_yaml::Value::String("path".to_string());
            let Some(current) = entry.get(&path_key).and_then(serde_yaml::Value::as_str) else {
                continue;
            };
            let Some(safe) = contained_provider_path(current, name.as_str()) else {
                continue;
            };
            tracing::warn!(
                "prepare_ios_config: {section} '{}' path '{current}' escapes the provider \
                 directory; rewriting to '{safe}' inside the App Group container",
                name.as_str().unwrap_or("?"),
            );
            entry.insert(path_key, serde_yaml::Value::String(safe));
        }
    }
}

/// Return `Some(replacement)` when `path` would escape the provider cache
/// directory, or `None` when it is already contained and must be left alone.
///
/// Lexical, not filesystem-based: the cache dir is the App Group container at
/// runtime and does not exist during unit tests, so `canonicalize` is not
/// available here. meow-rs re-checks the result against the real directory
/// anyway — this pass only has to stop handing it a path it will reject.
fn contained_provider_path(path: &str, name: Option<&str>) -> Option<String> {
    use std::path::{Component, Path};

    let p = Path::new(path);
    let escapes = p.is_absolute()
        || p.components()
            .any(|c| matches!(c, Component::ParentDir | Component::Prefix(_)));
    if !escapes {
        return None;
    }

    // Prefer the original file name so a rewritten provider keeps a
    // recognizable on-disk identity; fall back to the provider's key when the
    // path has no usable final component (`/`, `..`, …).
    let basename = p
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && *s != ".." && *s != ".")
        .or(name)
        .unwrap_or("provider");
    Some(format!("./{basename}"))
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
    //
    // `new_with_proxy_resolver` (meow-rs #420) honours
    // `dns.proxy-server-nameserver` when set: proxy-server hostnames then
    // resolve only through that dedicated resolver, matching mihomo. When
    // unset, `proxy_resolver` is `None` and the hook uses the main resolver.
    // Always install: iOS is a VPN platform and `meow_patch_config` pins
    // `dns.enable: true`, so the stub-resolver-when-DNS-off desktop path
    // does not apply.
    meow_common::set_host_resolver(Arc::new(
        meow_dns::ResolverHostHook::new_with_proxy_resolver(
            resolver.clone(),
            cfg.dns.proxy_resolver.clone(),
        ),
    ));

    let tunnel = Tunnel::new(resolver.clone());
    tunnel.set_mode(cfg.general.mode);
    tunnel.update_rules(cfg.rules);
    tunnel.update_proxies(cfg.proxies);

    // Start the tunnel's background tasks — the UDP NAT sweeper, which evicts
    // sessions idle > DEFAULT_UDP_IDLE (60 s) every DEFAULT_SWEEP_INTERVAL
    // (15 s), plus the 1 s stats-sampling ticker. Without the sweeper the
    // `nat_table` (and the `reply_readers` set + detached reader tasks the FFI
    // keys off it) grows monotonically under UDP flow churn: every new 5-tuple
    // inserts an `Arc<UdpSession>` that is only removed on a reader-task exit
    // that a quiet session (one-shot DNS, abandoned QUIC, dead upstream) never
    // reaches. Over hours that slow growth crosses the ~50 MB NE jetsam cap
    // and the PacketTunnel is killed. `meow-app` calls this after building
    // its tunnel; the FFI must too.
    //
    // We do NOT call upstream `Tunnel::spawn_background_tasks`: its stats
    // ticker holds a STRONG `Arc<Statistics>` and loops forever with no exit
    // condition, so every engine start→stop cycle would leak one task plus one
    // retained `Statistics` — unbounded across in-place restarts. Spawn both
    // tasks ourselves instead: the sweeper is already Weak-gated upstream
    // (exits when the nat table drops), and our ticker holds a `Weak` and
    // exits once this generation's `Statistics` is dropped on engine stop.
    //
    // `start()` runs on the main thread, OUTSIDE the tokio runtime, and both
    // spawns use a bare `tokio::spawn` (unlike the
    // `get_engine_runtime().spawn(...)` callsites below, which carry their own
    // handle). Enter the runtime context for the call so the tasks land on the
    // meow-engine runtime instead of panicking with "no reactor running". The
    // guard only needs to outlive the spawn.
    {
        let _enter = crate::get_engine_runtime().enter();
        meow_tunnel::udp::spawn_nat_sweeper(
            &tunnel.inner().nat_table,
            meow_tunnel::udp::DEFAULT_UDP_IDLE,
            meow_tunnel::udp::DEFAULT_SWEEP_INTERVAL,
        );
        let weak_stats = Arc::downgrade(tunnel.statistics());
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(1));
            // Consume tokio's immediate first tick; the first rate bucket is a
            // real one-second interval, matching upstream's ticker.
            ticker.tick().await;
            loop {
                ticker.tick().await;
                let Some(stats) = weak_stats.upgrade() else {
                    break;
                };
                stats.sample_traffic();
            }
        });
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
                let listener = MixedListener::new(tunnel.clone(), addr, nl.name.clone())
                    .with_sniffer(sniffer_runtime.clone())
                    .with_auth(auth.clone())
                    .with_max_connections(nl.max_connections);
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
    // `/providers/*`, `/rules`, `/listeners`, and `/logs` routes (and a 10th,
    // `external_ui`, in 0.16.0). Build the required shapes from the loaded
    // Config.
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
            raw_config.clone(),
            log_tx,
            proxy_providers,
            rule_providers,
            listeners,
            // external_ui (0.16.0): directory for the /ui web frontend.
            // The NE serves no web UI — the iOS app is the frontend.
            None,
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
        raw_config,
        api_task,
        listener_tasks,
    });
    Ok(())
}

/// Hot-reload mode/rules/proxies from `config_path` into the running engine.
///
/// Unlike `stop` → `start`, existing flows are NOT closed: in-flight
/// connection handlers hold `Arc` clones of the old route table and drain
/// naturally, only new flows see the new table — no DNS blackout, no TUN
/// disruption. Selector-group state resets (the proxies map is rebuilt), so
/// the host app must replay persisted selections after a successful reload.
///
/// Deliberately NOT reloaded (they are bound once at `start`): listeners,
/// the DNS server/resolver, fake-IP, and the REST controller itself. Changes
/// to those still require a stop→start. Proxy/rule *providers* are also
/// start-time state here; a reload swaps only the inline rules/proxies.
pub fn reload(config_path: &str) -> Result<()> {
    // Load + validate BEFORE touching the running engine: on a parse or
    // semantic error the old config keeps running untouched.
    let cfg = load_stripped_config(config_path)?;

    let guard = slot().lock();
    let state = guard.as_ref().context("engine not running")?;
    state.tunnel.set_mode(cfg.general.mode);
    state.tunnel.update_proxies(cfg.proxies);
    state.tunnel.update_rules(cfg.rules);
    *state.raw_config.write() = cfg.raw;
    info!("meow-rs engine config hot-reloaded");
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
        for k in ["port", "socks-port", "tproxy-port", "listeners"] {
            assert!(
                !m.contains_key(serde_yaml::Value::String(k.into())),
                "{k} should have been stripped",
            );
        }
        let sniffer = m
            .get(serde_yaml::Value::String("sniffer".into()))
            .and_then(|v| v.as_mapping())
            .expect("sniffer should survive runtime preparation");
        assert_eq!(sniffer.get("enable").and_then(|v| v.as_bool()), Some(true));
        assert_eq!(m.get("mixed-port").and_then(|v| v.as_i64()), Some(7892));
        assert_eq!(m.get("mode").and_then(|v| v.as_str()), Some("rule"));
        assert_eq!(m.get("log-level").and_then(|v| v.as_str()), Some("info"));
    }

    #[test]
    fn prepare_injects_default_tcp_connect_timeout() {
        let out = prepare_ios_config("mode: rule\n").expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        assert_eq!(
            doc.as_mapping()
                .unwrap()
                .get(serde_yaml::Value::String("tcp-connect-timeout".into()))
                .and_then(|v| v.as_i64()),
            Some(10),
            "iOS default DIRECT connect bound must be injected"
        );
    }

    #[test]
    fn prepare_preserves_user_tcp_connect_timeout() {
        let out = prepare_ios_config("mode: rule\ntcp-connect-timeout: 42\n").expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        assert_eq!(
            doc.as_mapping()
                .unwrap()
                .get(serde_yaml::Value::String("tcp-connect-timeout".into()))
                .and_then(|v| v.as_i64()),
            Some(42),
            "a user/subscription-set value must win over the injected default"
        );
    }

    /// Helper: run `prepare_ios_config` over a one-provider config and return
    /// the `path:` it emitted.
    fn prepared_provider_path(section: &str, path: &str) -> String {
        let yaml = format!(
            "mode: rule\n{section}:\n  cn:\n    type: http\n    behavior: domain\n    \
             url: https://example.test/cn.txt\n    path: {path}\n"
        );
        let out = prepare_ios_config(&yaml).expect("strip ok");
        let doc: serde_yaml::Value = serde_yaml::from_str(&out).unwrap();
        doc.as_mapping()
            .unwrap()
            .get(serde_yaml::Value::String(section.into()))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|m| m.get(serde_yaml::Value::String("cn".into())))
            .and_then(serde_yaml::Value::as_mapping)
            .and_then(|m| m.get(serde_yaml::Value::String("path".into())))
            .and_then(serde_yaml::Value::as_str)
            .expect("path key survives")
            .to_string()
    }

    #[test]
    fn contained_provider_paths_are_left_untouched() {
        // Configs authored for iOS must keep their exact on-disk layout,
        // subdirectories included — rewriting these would move the cache file
        // out from under an already-populated container.
        for path in ["./cn.txt", "cn.txt", "./ruleset/cn.txt", "ruleset/cn.txt"] {
            assert_eq!(
                prepared_provider_path("rule-providers", path),
                path,
                "contained path {path} must not be rewritten"
            );
        }
    }

    #[test]
    fn escaping_provider_paths_are_contained() {
        // Regression guard for the meow-rs #429 `safe_path` containment: these
        // shapes hard-fail `load_config` (verified against the pinned engine),
        // so `prepare_ios_config` has to normalize them or the tunnel never
        // starts. A desktop-exported profile is the common source.
        for section in ["rule-providers", "proxy-providers"] {
            assert_eq!(
                prepared_provider_path(section, "/Users/me/.config/meow/ruleset/cn.yaml"),
                "./cn.yaml",
                "{section}: an absolute desktop path must be contained by basename"
            );
            assert_eq!(
                prepared_provider_path(section, "../../etc/cn.txt"),
                "./cn.txt",
                "{section}: a `..` escape must be contained by basename"
            );
        }
    }

    #[test]
    fn escaping_provider_path_without_basename_falls_back_to_provider_name() {
        assert_eq!(
            prepared_provider_path("rule-providers", "/"),
            "./cn",
            "a path with no usable final component falls back to the provider key"
        );
    }

    fn load_yaml_in_tempdir(yaml: &str) -> anyhow::Result<meow_config::Config> {
        let dir = tempfile::tempdir().expect("tempdir");
        let f = dir.path().join("effective-config.yaml");
        std::fs::write(&f, yaml).unwrap();
        crate::get_engine_runtime().block_on(meow_config::load_config(f.to_str().unwrap()))
    }

    fn assert_prepared_escaping_provider_loads(section: &str, yaml: &str) {
        // End-to-end: the whole point of the rewrite is that the engine's own
        // loader accepts the result. Runs the prepared YAML through
        // `load_config` with a real cache dir, which is where meow-rs applies
        // the containment check. #458 made proxy-provider escapes a hard
        // rebuild failure (rule-provider parity), so both sections must pass.
        let prepared = prepare_ios_config(yaml).expect("strip ok");
        let res = load_yaml_in_tempdir(&prepared);
        assert!(
            res.is_ok(),
            "prepared {section} config must clear the engine's provider-path containment, got: {:?}",
            res.err()
        );
    }

    #[test]
    fn unprepared_escaping_rule_provider_path_is_rejected_by_engine() {
        // Pins that 0.21.0 still hard-fails #429 containment — the rewrite
        // in `prepare_ios_config` is load-bearing, not defensive.
        let yaml = "mixed-port: 7890\nproxies:\n  - name: p1\n    type: direct\nrules:\n  \
                    - MATCH,p1\nrule-providers:\n  cn:\n    type: http\n    behavior: domain\n    \
                    url: https://example.test/cn.txt\n    path: /var/mobile/ruleset/cn.txt\n    \
                    interval: 86400\n";
        let Err(err) = load_yaml_in_tempdir(yaml) else {
            panic!("escaping rule-provider path must fail load_config");
        };
        let msg = err.to_string();
        assert!(
            msg.contains("escapes"),
            "engine must reject the unprepared path, got: {msg}"
        );
    }

    #[test]
    fn unprepared_escaping_proxy_provider_path_is_rejected_by_engine() {
        // #458: proxy-provider escapes fail the whole rebuild, not warn-skip.
        let yaml = "mixed-port: 7890\nproxies:\n  - name: p1\n    type: direct\nrules:\n  \
                    - MATCH,p1\nproxy-providers:\n  nodes:\n    type: http\n    \
                    url: https://example.test/proxies.yaml\n    path: /Users/me/.config/meow/nodes.yaml\n    \
                    interval: 86400\n";
        let Err(err) = load_yaml_in_tempdir(yaml) else {
            panic!("escaping proxy-provider path must fail load_config");
        };
        let msg = err.to_string();
        assert!(
            msg.contains("escapes"),
            "engine must reject the unprepared path, got: {msg}"
        );
    }

    #[test]
    fn prepared_escaping_provider_config_actually_loads() {
        assert_prepared_escaping_provider_loads(
            "rule-providers",
            "mixed-port: 7890\nproxies:\n  - name: p1\n    type: direct\nrules:\n  \
             - MATCH,p1\nrule-providers:\n  cn:\n    type: http\n    behavior: domain\n    \
             url: https://example.test/cn.txt\n    path: /var/mobile/ruleset/cn.txt\n    \
             interval: 86400\n",
        );
    }

    #[test]
    fn prepared_escaping_proxy_provider_config_actually_loads() {
        // #458: proxy-provider containment violations now fail the whole
        // rebuild, not warn-skip. A desktop-exported `path:` would take the
        // tunnel down unless `prepare_ios_config` rewrites it first.
        assert_prepared_escaping_provider_loads(
            "proxy-providers",
            "mixed-port: 7890\nproxies:\n  - name: p1\n    type: direct\nrules:\n  \
             - MATCH,p1\nproxy-providers:\n  nodes:\n    type: http\n    \
             url: https://example.test/proxies.yaml\n    path: /Users/me/.config/meow/nodes.yaml\n    \
             interval: 86400\n",
        );
    }

    #[test]
    fn proxy_server_nameserver_builds_dedicated_resolver() {
        // meow-rs #420: `dns.proxy-server-nameserver` produces a dedicated
        // `proxy_resolver` that `start()` must hand to
        // `ResolverHostHook::new_with_proxy_resolver`. If this goes `None`
        // the hook silently falls back to the main resolver and the user's
        // proxy-server nameservers are ignored.
        let yaml = r#"
mixed-port: 7890
dns:
  enable: true
  nameserver: [8.8.8.8]
  proxy-server-nameserver: [1.1.1.1]
proxies:
  - name: p1
    type: direct
rules:
  - MATCH,p1
"#;
        let cfg = load_stripped_config_from_str(yaml).expect("config loads");
        assert!(cfg.dns.enabled, "dns.enable: true must survive prepare");
        assert!(
            cfg.dns.proxy_resolver.is_some(),
            "proxy-server-nameserver must produce a dedicated resolver"
        );
    }

    #[test]
    fn no_proxy_server_nameserver_leaves_proxy_resolver_none() {
        let yaml = r#"
mixed-port: 7890
dns:
  enable: true
  nameserver: [8.8.8.8]
proxies:
  - name: p1
    type: direct
rules:
  - MATCH,p1
"#;
        let cfg = load_stripped_config_from_str(yaml).expect("config loads");
        assert!(
            cfg.dns.proxy_resolver.is_none(),
            "without proxy-server-nameserver the hook must use the main resolver"
        );
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
  store-fake-ip: true
  nameserver:
    - 119.29.29.29
sniffer:
  enable: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    TLS:
      ports: [443, 8443]
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
        assert!(cfg.sniffer.enable);
        assert!(cfg.sniffer.parse_pure_ip);
        assert!(!cfg.sniffer.override_destination);
        assert_eq!(cfg.sniffer.tls_ports, vec![443, 8443]);
        assert!(cfg.sniffer.http_ports.is_empty());
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
        //            + the injected mihomo-compat GLOBAL selector (meow-rs
        //            0.18, #313) = 23. The app hides GLOBAL in
        //            ProxyGroupModel, so it never reaches the UI.
        assert_eq!(
            leaves.len(),
            144,
            "expected 141 ss proxies + 3 built-ins; if this drops to 3, \
             meow-config was built without the `ss` feature — see commit \
             enabling default features on the meow-config dep",
        );
        assert_eq!(
            groups.len(),
            23,
            "all 22 user-defined groups plus injected GLOBAL must resolve",
        );
    }

    /// One proxy of every protocol compiled into this build (meow-config
    /// defaults + the explicit `anytls` opt-in). Asserted by name so a
    /// silently dropped feature flag — which warn-skips the entry in lenient
    /// parsing instead of erroring — fails loudly here. Companion to the
    /// `ss`-only regression test above; see the meow-config dep comment in
    /// Cargo.toml for the full feature inventory.
    #[test]
    fn every_compiled_protocol_parses() {
        let yaml = r#"
proxies:
  - {name: p-ss, type: ss, server: 1.2.3.4, port: 8388, cipher: aes-256-gcm, password: pw}
  - {name: p-trojan, type: trojan, server: 1.2.3.4, port: 443, password: pw}
  - {name: p-vless, type: vless, server: 1.2.3.4, port: 443, uuid: 8b1e3b64-3c7e-4a2d-9c7d-000000000001}
  - {name: p-vmess, type: vmess, server: 1.2.3.4, port: 443, uuid: 8b1e3b64-3c7e-4a2d-9c7d-000000000002}
  - {name: p-snell, type: snell, server: 1.2.3.4, port: 8388, psk: secret}
  - {name: p-hysteria2, type: hysteria2, server: 1.2.3.4, port: 443, password: pw}
  - {name: p-anytls, type: anytls, server: 1.2.3.4, port: 443, password: pw}
rules:
  - MATCH,DIRECT
"#;
        let stripped = super::prepare_ios_config(yaml).expect("strip ok");
        let rt = tokio::runtime::Runtime::new().expect("tokio rt");
        // block_on provides the live reactor the anytls adapter's pool-reaper
        // spawn needs at parse time.
        let cfg = rt
            .block_on(meow_config::load_config_from_str(&stripped))
            .expect("full-protocol config must load");

        for name in [
            "p-ss",
            "p-trojan",
            "p-vless",
            "p-vmess",
            "p-snell",
            "p-hysteria2",
            "p-anytls",
        ] {
            assert!(
                cfg.proxies.contains_key(name),
                "{name} missing after parse — its protocol feature was \
                 compiled out or the parser rejected the minimal entry",
            );
        }
    }
}
