//! Embedded mihomo-rust engine. Owns the REST API and DNS server tasks and
//! holds the `Tunnel` used directly (in-process) by `tun2socks` — there is no
//! local SOCKS listener; TCP flows hop Rust-to-Rust through a shared
//! `Arc<TunnelInner>` rather than through a loopback socket.
//!
//! Lifecycle: `start(config_path)` spawns the REST API and (optional) DNS
//! listener on the shared tokio runtime and keeps their `JoinHandle`s in
//! `EngineState`. `stop()` aborts those tasks and *blocks* on them before
//! returning — dropping the futures drops the `TcpListener`/`UdpSocket` and
//! releases the ports synchronously, so a fast `start → stop → start` cycle
//! doesn't race the previous bind (`EADDRINUSE`).
use anyhow::Result;
use dashmap::DashMap;
use mihomo_api::log_stream::{LogBroadcastLayer, LogMessage};
use mihomo_api::ApiServer;
use mihomo_config::{load_config, load_config_from_str};
use mihomo_dns::DnsServer;
use mihomo_tunnel::{Statistics, Tunnel};
use parking_lot::{Mutex, RwLock};
use std::collections::HashMap;
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
    dns_task: Option<JoinHandle<()>>,
}

fn slot() -> &'static Mutex<Option<EngineState>> {
    static S: OnceLock<Mutex<Option<EngineState>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

fn install_tls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
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
        let log_layer = LogBroadcastLayer { tx: log_broadcast_tx().clone() }
            .with_filter(LevelFilter::TRACE);
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

    // `load_config` is async as of the 2026-04-19 mihomo-rust bump
    // (rule-provider cache is fetched eagerly during config build). Bridge to
    // our shared runtime rather than spawning a single-use one.
    let cfg = crate::get_runtime().block_on(load_config(config_path))?;
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

    let dns_task = cfg.dns.listen_addr.map(|addr| {
        let resolver = cfg.dns.resolver.clone();
        crate::get_runtime().spawn(async move {
            let dns_server = DnsServer::new(resolver, addr);
            if let Err(e) = dns_server.run().await {
                error!("DNS server error: {}", e);
            }
        })
    });

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

    *slot().lock() = Some(EngineState { stats, tunnel, api_task, dns_task });
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
    if let Some(h) = state.dns_task {
        h.abort();
        let _ = runtime.block_on(h);
    }
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
    let _ = crate::get_runtime().block_on(load_config_from_str(yaml))?;
    Ok(())
}
