//! Embedded mihomo-rust engine. Owns the REST API, DNS server, and local
//! SOCKS/Mixed listener that the tun2socks layer dials into.
//!
//! The lifecycle is single-shot: `start(config_path)` spawns all tasks on the
//! shared tokio runtime; `stop()` fires a `Notify` that the supervisor task
//! awaits on before returning — individual listeners/servers exit when the
//! runtime is dropped. Statistics are exposed as atomic counters so the
//! traffic pump can read them without going through the REST API.
use anyhow::Result;
use mihomo_api::ApiServer;
use mihomo_config::{load_config, load_config_from_str};
use mihomo_dns::DnsServer;
use mihomo_listener::MixedListener;
use mihomo_tunnel::{Statistics, Tunnel};
use parking_lot::{Mutex, RwLock};
use std::net::SocketAddr;
use std::sync::{Arc, OnceLock};
use tokio::sync::Notify;
use tracing::{error, info, warn};

struct EngineState {
    shutdown: Arc<Notify>,
    stats: Arc<Statistics>,
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

    let bind_addr = cfg.general.bind_address.clone();
    let mixed_port = cfg.listeners.mixed_port.or(cfg.listeners.socks_port);
    let dns_listen = cfg.dns.listen_addr;
    let dns_resolver = cfg.dns.resolver.clone();
    let api_addr = cfg.api.external_controller;
    let api_secret = cfg.api.secret.clone();
    let config_path_owned = config_path.to_string();

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
                    tunnel.clone(),
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

            if let Some(port) = mixed_port {
                match format!("{}:{}", bind_addr, port).parse::<SocketAddr>() {
                    Ok(addr) => {
                        let listener = MixedListener::new(tunnel.clone(), addr);
                        tokio::spawn(async move {
                            if let Err(e) = listener.run().await {
                                error!("SOCKS/Mixed listener error: {}", e);
                            }
                        });
                    }
                    Err(e) => error!("bad bind address '{}:{}': {}", bind_addr, port, e),
                }
            } else {
                warn!("no mixed-port/socks-port configured — tun2socks has nowhere to dial");
            }

            info!("mihomo-rust engine running");
            shutdown.notified().await;
            info!("mihomo-rust engine stopped");
        }
    });

    *slot().lock() = Some(EngineState { shutdown, stats });
    Ok(())
}

pub fn stop() {
    if let Some(state) = slot().lock().take() {
        state.shutdown.notify_waiters();
    }
}

pub fn traffic() -> (i64, i64) {
    slot()
        .lock()
        .as_ref()
        .map(|s| s.stats.snapshot())
        .unwrap_or((0, 0))
}

pub fn validate(yaml: &str) -> Result<()> {
    install_tls_provider();
    let _ = load_config_from_str(yaml)?;
    Ok(())
}
