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
use mihomo_api::ApiServer;
use mihomo_config::{load_config, load_config_from_str};
use mihomo_dns::DnsServer;
use mihomo_tunnel::{Statistics, Tunnel};
use parking_lot::{Mutex, RwLock};
use std::sync::{Arc, OnceLock};
use tokio::task::JoinHandle;
use tracing::{error, info};

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

pub fn start(config_path: &str) -> Result<()> {
    if slot().lock().is_some() {
        return Ok(());
    }

    install_tls_provider();

    let cfg = load_config(config_path)?;
    let raw_config = Arc::new(RwLock::new(cfg.raw.clone()));

    let tunnel = Tunnel::new(cfg.dns.resolver.clone());
    tunnel.set_mode(cfg.general.mode);
    tunnel.update_rules(cfg.rules);
    tunnel.update_proxies(cfg.proxies);
    let stats = tunnel.statistics().clone();

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
    let _ = load_config_from_str(yaml)?;
    Ok(())
}
