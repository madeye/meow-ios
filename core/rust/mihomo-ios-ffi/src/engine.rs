//! Embedded mihomo-rust engine. Owns the REST API and DNS server tasks and
//! holds the `Tunnel` used directly (in-process) by `tun2socks` — there is no
//! local SOCKS listener; TCP flows hop Rust-to-Rust through a shared
//! `Arc<TunnelInner>` rather than through a loopback socket.
//!
//! Lifecycle is single-shot: `start(config_path)` spawns supervisor tasks on
//! the shared tokio runtime; `stop()` fires a `Notify` the supervisor awaits
//! before exiting — listeners/servers tear down when the runtime is dropped.
use anyhow::Result;
use mihomo_api::ApiServer;
use mihomo_config::{load_config, load_config_from_str};
use mihomo_dns::DnsServer;
use mihomo_tunnel::{Statistics, Tunnel};
use parking_lot::{Mutex, RwLock};
use std::sync::{Arc, OnceLock};
use tokio::sync::Notify;
use tracing::{error, info};

struct EngineState {
    shutdown: Arc<Notify>,
    stats: Arc<Statistics>,
    tunnel: Tunnel,
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
    let shutdown = Arc::new(Notify::new());

    let tunnel = Tunnel::new(cfg.dns.resolver.clone());
    tunnel.set_mode(cfg.general.mode);
    tunnel.update_rules(cfg.rules);
    tunnel.update_proxies(cfg.proxies);
    let stats = tunnel.statistics().clone();

    let dns_listen = cfg.dns.listen_addr;
    let dns_resolver = cfg.dns.resolver.clone();
    let api_addr = cfg.api.external_controller;
    let api_secret = cfg.api.secret.clone();
    let config_path_owned = config_path.to_string();

    let tunnel_for_task = tunnel.clone();
    crate::get_runtime().spawn({
        let shutdown = shutdown.clone();
        async move {
            if let Some(addr) = dns_listen {
                let dns_server = DnsServer::new(dns_resolver, addr);
                tokio::spawn(async move {
                    if let Err(e) = dns_server.run().await {
                        error!("DNS server error: {}", e);
                    }
                });
            }

            if let Some(addr) = api_addr {
                let api_server = ApiServer::new(
                    tunnel_for_task,
                    addr,
                    api_secret,
                    config_path_owned,
                    raw_config,
                );
                tokio::spawn(async move {
                    if let Err(e) = api_server.run().await {
                        error!("API server error: {}", e);
                    }
                });
            }

            info!("mihomo-rust engine running (in-process dispatch)");
            shutdown.notified().await;
            info!("mihomo-rust engine stopped");
        }
    });

    *slot().lock() = Some(EngineState { shutdown, stats, tunnel });
    Ok(())
}

pub fn stop() {
    if let Some(state) = slot().lock().take() {
        state.shutdown.notify_waiters();
    }
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
