//! DNS-over-HTTPS client. Each request runs over a `tokio::io::duplex` pair
//! whose far end is handed to `mihomo_tunnel::tcp::handle_tcp` — the same
//! in-process Rust-to-Rust dispatch path the netstack TCP flows take in
//! `tun2socks::dispatch_tcp`. There is no loopback SOCKS listener; mihomo
//! sees the TLS bytes the same way it sees TUN-originated TCP.

use crate::dns_table;
use crate::doh_cache;
use crate::engine;
use crate::logging;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::client::conn::http2;
use hyper::header::{ACCEPT, CONTENT_TYPE};
use hyper::{Method, Request, Uri};
use hyper_util::rt::{TokioExecutor, TokioIo};
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use parking_lot::Mutex;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio_rustls::TlsConnector;
use tracing::{info, warn};

const DOH_TIMEOUT_SECS: u64 = 5;
const DUPLEX_BUF_SIZE: usize = 64 * 1024;

const IP_BASED_DOH_URLS: &[&str] = &["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"];

// Answer cache: collapses duplicate in-flight queries (e.g. the 17:30:45
// reconnect burst that hit `app-measurement.com` 5×, `app-analytics-services.com`
// 4×, `www.google.com` 2× within a single millisecond, each paying the full
// 128 KiB-duplex + TLS + mihomo-flow cost). Keyed on the raw question section
// (name + qtype + qclass); txid is patched onto the cached response per request.
const CACHE_MAX_ENTRIES: usize = 1024;
const CACHE_TTL_FLOOR: Duration = Duration::from_secs(10);
const CACHE_TTL_CEIL: Duration = Duration::from_secs(300);
const CACHE_TTL_DEFAULT: Duration = Duration::from_secs(60);

type CacheEntry = (Vec<u8>, Instant);
type AnswerCache = Mutex<HashMap<Vec<u8>, CacheEntry>>;

fn cache() -> &'static AnswerCache {
    static C: OnceLock<AnswerCache> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

// In-flight single-flight: when N identical queries arrive concurrently
// (the canonical reconnect-burst case), only the first issues a real lookup;
// the rest subscribe to the leader's broadcast and reuse its result, sparing
// N-1 mihomo flows + duplex pairs + TLS handshakes.
type Inflight = Mutex<HashMap<Vec<u8>, broadcast::Sender<Option<Vec<u8>>>>>;

fn inflight() -> &'static Inflight {
    static I: OnceLock<Inflight> = OnceLock::new();
    I.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Owns the inflight-map entry for a leader request. On drop without
/// `complete()` (i.e. the leader future was cancelled), the entry is purged
/// and `tx` is dropped — followers see `Err(Closed)` from `recv()` and bail.
struct LeaderGuard {
    key: Vec<u8>,
    tx: broadcast::Sender<Option<Vec<u8>>>,
    completed: bool,
}

impl LeaderGuard {
    fn complete(mut self, result: Option<Vec<u8>>) {
        // Remove first so concurrent callers can't subscribe after we send.
        inflight().lock().remove(&self.key);
        let _ = self.tx.send(result);
        self.completed = true;
    }
}

impl Drop for LeaderGuard {
    fn drop(&mut self) {
        if !self.completed {
            inflight().lock().remove(&self.key);
        }
    }
}

/// Aborts a spawned task when this guard drops. Used to tear down the
/// `handle_tcp` mihomo flow and the hyper connection driver if `send_doh`
/// returns early (timeout, TLS error, request error) instead of leaving them
/// detached to finish their own setup before noticing the duplex EOF.
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn patch_txid(resp: &mut [u8], query: &[u8]) {
    if resp.len() >= 2 && query.len() >= 2 {
        resp[0] = query[0];
        resp[1] = query[1];
    }
}

/// Returns the bytes of the question section (qname + qtype + qclass) starting
/// at offset 12, suitable for use as a cache key. Walks uncompressed labels —
/// queries from clients don't use compression in the question.
fn question_section(query: &[u8]) -> Option<&[u8]> {
    if query.len() < 12 {
        return None;
    }
    let mut i = 12usize;
    loop {
        if i >= query.len() {
            return None;
        }
        let len = query[i];
        if len == 0 {
            i += 1;
            break;
        }
        if len & 0xc0 != 0 {
            // compression pointer (2 bytes) — not expected in client queries,
            // but bail rather than mis-parse.
            return None;
        }
        i += 1 + len as usize;
        if i > query.len() {
            return None;
        }
    }
    if i + 4 > query.len() {
        return None;
    }
    Some(&query[12..i + 4])
}

/// TTL to cache a response for: min TTL across A/AAAA records, clamped to
/// [`CACHE_TTL_FLOOR`, `CACHE_TTL_CEIL`]. Empty/unparseable responses get
/// `CACHE_TTL_DEFAULT` so NXDOMAIN bursts are still collapsed.
fn cache_ttl(response: &[u8]) -> Duration {
    let records = dns_table::parse_dns_response_records(response);
    let min_ttl = records.iter().map(|(_, _, ttl)| *ttl).min();
    match min_ttl {
        Some(ttl) => Duration::from_secs(ttl as u64).clamp(CACHE_TTL_FLOOR, CACHE_TTL_CEIL),
        None => CACHE_TTL_DEFAULT,
    }
}

struct DohClient {
    doh_urls: Vec<String>,
    tls_config: Arc<ClientConfig>,
}

static DOH_CLIENT: OnceLock<DohClient> = OnceLock::new();

pub fn init_doh_client() {
    DOH_CLIENT.get_or_init(|| {
        let (doh_urls, china_upstreams) = read_dns_config();
        info!("DoH client (in-process dispatch): urls={:?}", doh_urls);

        // Open the persistent answer cache and hydrate the in-memory map from
        // its unexpired entries. Cold-start now reuses warm DoH answers from
        // prior PacketTunnel runs instead of re-paying the launch-burst.
        let home_dir_for_geoip = {
            let home_dir = crate::HOME_DIR.lock();
            doh_cache::init(home_dir.as_deref());
            home_dir.clone()
        };
        hydrate_in_memory_from_disk();

        // Wire the trust-china-dns split-horizon layer. Reads `Country.mmdb`
        // from the same `$HOME_DIR/mihomo/` path mihomo's engine uses; if the
        // file is missing the orchestrator quietly degrades to DoH-only.
        crate::china_dns::init(home_dir_for_geoip.as_deref(), china_upstreams);

        // The DoH path can traverse arbitrary upstream proxies the user
        // configured; matching the previous reqwest behavior, accept any
        // server cert. The DNS payload itself is not a secret and we trust
        // the proxy operator (i.e. the user).
        let mut tls_config = ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertVerify))
            .with_no_client_auth();
        // Negotiate HTTP/2 on the DoH connection so a single TLS session
        // multiplexes burst queries instead of paying handshake-per-query.
        tls_config.alpn_protocols = vec![b"h2".to_vec()];

        DohClient {
            doh_urls,
            tls_config: Arc::new(tls_config),
        }
    });
}

fn hydrate_in_memory_from_disk() {
    let entries = doh_cache::load_unexpired();
    if entries.is_empty() {
        return;
    }
    let now = Instant::now();
    let mut cache = cache().lock();
    for (k, bytes, expires_unix_secs) in entries {
        if cache.len() >= CACHE_MAX_ENTRIES {
            break;
        }
        let ttl = doh_cache::expires_in(expires_unix_secs);
        if ttl.is_zero() {
            continue;
        }
        cache.insert(k, (bytes, now + ttl));
    }
    info!("doh cache: hydrated {} entries from disk", cache.len());
}

pub async fn resolve_via_doh(query: &[u8]) -> Option<Vec<u8>> {
    let client = DOH_CLIENT.get()?;

    let key = question_section(query).map(|q| q.to_vec());

    // Cache check.
    if let Some(ref k) = key {
        let now = Instant::now();
        let mut cache = cache().lock();
        if let Some((bytes, expires)) = cache.get(k) {
            if *expires > now {
                let mut resp = bytes.clone();
                patch_txid(&mut resp, query);
                return Some(resp);
            }
            cache.remove(k);
            drop(cache);
            doh_cache::remove(k);
        }
    }

    // Single-flight: either become the leader (issue the lookup, broadcast
    // the result) or follow an existing leader. Queries with no parseable key
    // skip dedup and just run.
    enum Role {
        Leader(broadcast::Sender<Option<Vec<u8>>>),
        Follower(broadcast::Receiver<Option<Vec<u8>>>),
    }
    let role = key.as_ref().map(|k| {
        let mut map = inflight().lock();
        match map.get(k) {
            Some(tx) => Role::Follower(tx.subscribe()),
            None => {
                let (tx, _) = broadcast::channel(1);
                map.insert(k.clone(), tx.clone());
                Role::Leader(tx)
            }
        }
    });

    let leader_guard = match role {
        Some(Role::Follower(mut rx)) => {
            return match rx.recv().await {
                Ok(Some(bytes)) => {
                    let mut resp = bytes;
                    patch_txid(&mut resp, query);
                    Some(resp)
                }
                // Leader failed (Ok(None)) or was cancelled (Err(_)).
                _ => None,
            };
        }
        Some(Role::Leader(tx)) => Some(LeaderGuard {
            key: key.clone().expect("Leader implies key present"),
            tx,
            completed: false,
        }),
        None => None,
    };

    let result = run_doh_attempts(client, query).await;

    // Cache successful result.
    if let (Some(k), Some(bytes)) = (key.as_ref(), result.as_ref()) {
        let ttl = cache_ttl(bytes);
        let expires_unix = doh_cache::unix_secs_in(ttl);
        let mut evicted: Option<Vec<u8>> = None;
        {
            let mut cache = cache().lock();
            if cache.len() >= CACHE_MAX_ENTRIES {
                // Evict the entry closest to expiry — cheap O(n) at n≤1024 and
                // naturally biases toward dropping near-stale entries before fresh
                // ones.
                if let Some(oldest) = cache
                    .iter()
                    .min_by_key(|(_, (_, e))| *e)
                    .map(|(k, _)| k.clone())
                {
                    cache.remove(&oldest);
                    evicted = Some(oldest);
                }
            }
            cache.insert(k.clone(), (bytes.clone(), Instant::now() + ttl));
        }
        if let Some(e) = evicted {
            doh_cache::remove(&e);
        }
        doh_cache::put(k, bytes, expires_unix);
    }

    if let Some(guard) = leader_guard {
        guard.complete(result.clone());
    }

    result
}

async fn run_doh_attempts(client: &DohClient, query: &[u8]) -> Option<Vec<u8>> {
    for url in &client.doh_urls {
        match tokio::time::timeout(
            Duration::from_secs(DOH_TIMEOUT_SECS),
            send_doh(client, url, query),
        )
        .await
        {
            Ok(Ok(bytes)) => return Some(bytes),
            Ok(Err(e)) => warn!("DoH request failed to {}: {}", url, e),
            Err(_) => {
                // Outer timeout fired — the inflight request future is dropped.
                // Evict the pooled connection so the next query for this URL
                // reopens a fresh TLS + h2 session instead of reusing what may
                // be a stuck mihomo flow behind the timed-out stream.
                warn!("DoH request timed out to {}", url);
                evict_pool_entry(url);
            }
        }
    }

    logging::bridge_log("DoH: all servers failed");
    None
}

// HTTP/2 connection pool keyed by DoH URL. Each entry holds the multiplexed
// `SendRequest` plus abort guards for the spawned mihomo flow and h2 driver,
// so dropping the entry tears the whole stack down. Burst DNS queries clone
// the sender and ride as concurrent h2 streams over the single TLS session.
const POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

struct PoolEntry {
    sender: http2::SendRequest<Full<Bytes>>,
    last_used: Instant,
    _flow_guard: AbortOnDrop,
    _driver_guard: AbortOnDrop,
}

type Pool = Mutex<HashMap<String, PoolEntry>>;

fn pool() -> &'static Pool {
    static P: OnceLock<Pool> = OnceLock::new();
    P.get_or_init(|| Mutex::new(HashMap::new()))
}

async fn send_doh(client: &DohClient, url: &str, query: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    // First attempt over a (possibly reused) pooled connection.
    match try_send(client, url, query).await {
        Ok(bytes) => Ok(bytes),
        Err(e) => {
            // Always evict on failure: the next query for this URL will open a
            // fresh TLS + h2 session rather than reuse a connection whose
            // mihomo flow may have stalled.
            evict_pool_entry(url);
            // Retry once on connection-layer errors — a pooled sender may have
            // raced with a server-side close, and a fresh connection should
            // succeed without escalating to the next URL.
            if is_conn_error(&e) {
                try_send(client, url, query).await.inspect_err(|_| {
                    evict_pool_entry(url);
                })
            } else {
                Err(e)
            }
        }
    }
}

async fn try_send(client: &DohClient, url: &str, query: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    let uri: Uri = url.parse()?;
    let mut sender = acquire_sender(client, url, &uri).await?;

    let req = Request::builder()
        .method(Method::POST)
        .uri(&uri)
        .header(CONTENT_TYPE, "application/dns-message")
        .header(ACCEPT, "application/dns-message")
        .body(Full::new(Bytes::copy_from_slice(query)))?;

    let resp = sender.send_request(req).await?;
    if !resp.status().is_success() {
        anyhow::bail!("HTTP {}", resp.status());
    }
    let body = resp.into_body().collect().await?.to_bytes();
    Ok(body.to_vec())
}

fn is_conn_error(err: &anyhow::Error) -> bool {
    if let Some(hyper_err) = err.downcast_ref::<hyper::Error>() {
        return hyper_err.is_closed()
            || hyper_err.is_canceled()
            || hyper_err.is_incomplete_message();
    }
    false
}

fn evict_pool_entry(url: &str) {
    pool().lock().remove(url);
}

async fn acquire_sender(
    client: &DohClient,
    url: &str,
    uri: &Uri,
) -> Result<http2::SendRequest<Full<Bytes>>, anyhow::Error> {
    // Fast path: live, non-stale entry already in the pool.
    {
        let mut p = pool().lock();
        sweep_pool(&mut p);
        if let Some(entry) = p.get_mut(url) {
            entry.last_used = Instant::now();
            return Ok(entry.sender.clone());
        }
    }

    // Slow path: open a new connection without holding the pool lock. A
    // concurrent caller may race us; whichever insert lands second tears down
    // its own duplicate via the dropped abort guards.
    let new_entry = open_connection(client, uri).await?;
    let sender = new_entry.sender.clone();

    let mut p = pool().lock();
    if let Some(existing) = p.get_mut(url) {
        if !existing.sender.is_closed() {
            existing.last_used = Instant::now();
            return Ok(existing.sender.clone());
        }
    }
    p.insert(url.to_string(), new_entry);
    Ok(sender)
}

fn sweep_pool(p: &mut HashMap<String, PoolEntry>) {
    let now = Instant::now();
    p.retain(|_, e| !e.sender.is_closed() && now.duration_since(e.last_used) < POOL_IDLE_TIMEOUT);
}

async fn open_connection(client: &DohClient, uri: &Uri) -> Result<PoolEntry, anyhow::Error> {
    let scheme = uri.scheme_str().unwrap_or("");
    if scheme != "https" {
        anyhow::bail!("non-https DoH URL: {}", uri);
    }
    let host = uri
        .host()
        .ok_or_else(|| anyhow::anyhow!("URL missing host"))?
        .to_string();
    let port = uri.port_u16().unwrap_or(443);

    let tunnel = engine::tunnel().ok_or_else(|| anyhow::anyhow!("engine not running"))?;

    // Mirror tun2socks::dispatch_tcp's metadata population (see
    // tun2socks.rs:286-295). For DoH the destination may already be an IP
    // literal (e.g. "https://1.1.1.1/dns-query") — populate `dst_ip` in that
    // case and leave `host` empty so mihomo doesn't try to re-resolve.
    let dst_ip = host.parse().ok();
    let metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Inner,
        src_ip: None,
        src_port: 0,
        dst_ip,
        dst_port: port,
        host: if dst_ip.is_some() {
            String::new()
        } else {
            host.clone()
        },
        ..Default::default()
    };

    let (left, right) = tokio::io::duplex(DUPLEX_BUF_SIZE);
    let proxy_conn: Box<dyn ProxyConn> = Box::new(DuplexConn(right));
    let inner = tunnel.inner().clone();
    let flow_guard = AbortOnDrop(tokio::spawn(async move {
        mihomo_tunnel::tcp::handle_tcp(&inner, proxy_conn, metadata).await;
    }));

    let server_name = ServerName::try_from(host)?;
    let tls_stream = TlsConnector::from(client.tls_config.clone())
        .connect(server_name, left)
        .await?;

    let (sender, conn) = http2::handshake(TokioExecutor::new(), TokioIo::new(tls_stream)).await?;
    let driver_guard = AbortOnDrop(tokio::spawn(async move {
        if let Err(e) = conn.await {
            warn!("DoH connection driver error: {}", e);
        }
    }));

    Ok(PoolEntry {
        sender,
        last_used: Instant::now(),
        _flow_guard: flow_guard,
        _driver_guard: driver_guard,
    })
}

// `ProxyConn` requires the wrapper to be local (orphan rule), so we hand
// mihomo this newtype around tokio's `DuplexStream`.
struct DuplexConn(DuplexStream);

impl AsyncRead for DuplexConn {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl AsyncWrite for DuplexConn {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

impl ProxyConn for DuplexConn {}

#[derive(Debug)]
struct NoCertVerify;

impl ServerCertVerifier for NoCertVerify {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ED25519,
            SignatureScheme::ED448,
        ]
    }
}

#[derive(serde::Deserialize)]
struct MinimalConfig {
    dns: Option<MinimalDns>,
}

#[derive(serde::Deserialize)]
struct MinimalDns {
    nameserver: Option<Vec<serde_yaml::Value>>,
    fallback: Option<Vec<serde_yaml::Value>>,
    /// `china_dns`-only field — Chinese plain-UDP nameservers, raced
    /// first-response-wins. `None` (key missing) → use built-in defaults
    /// (DNSPod + AliDNS). `Some(empty)` → disable the split entirely.
    china_nameserver: Option<Vec<serde_yaml::Value>>,
}

fn default_doh_urls() -> Vec<String> {
    IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect()
}

/// Reads `config.yaml` once for both the DoH upstream pool and the China-side
/// UDP nameservers consumed by `china_dns::init`. Falls back to the built-in
/// defaults on any error: missing file, malformed YAML, missing `dns:` block.
fn read_dns_config() -> (Vec<String>, Vec<std::net::SocketAddr>) {
    let home_dir = crate::HOME_DIR.lock();
    let config_path = match home_dir.as_ref() {
        Some(dir) => format!("{}/config.yaml", dir),
        None => {
            info!("DoH: no HOME_DIR, using default URLs");
            return (
                default_doh_urls(),
                crate::china_dns::default_china_upstreams(),
            );
        }
    };
    drop(home_dir);

    let config_str = match std::fs::read_to_string(&config_path) {
        Ok(s) => s,
        Err(e) => {
            warn!("DoH: cannot read {}: {}", config_path, e);
            return (
                default_doh_urls(),
                crate::china_dns::default_china_upstreams(),
            );
        }
    };

    let config: MinimalConfig = match serde_yaml::from_str(&config_str) {
        Ok(c) => c,
        Err(e) => {
            warn!("DoH: cannot parse config: {}", e);
            return (
                default_doh_urls(),
                crate::china_dns::default_china_upstreams(),
            );
        }
    };

    let mut urls = Vec::new();
    let mut china = None;
    if let Some(dns) = config.dns {
        for list in [dns.nameserver, dns.fallback].into_iter().flatten() {
            for entry in list {
                if let serde_yaml::Value::String(s) = entry {
                    if s.starts_with("https://") && !urls.contains(&s) {
                        urls.push(s);
                    }
                }
            }
        }
        china = dns.china_nameserver.map(parse_china_upstreams);
    }

    for fallback in IP_BASED_DOH_URLS {
        let s = fallback.to_string();
        if !urls.contains(&s) {
            urls.push(s);
        }
    }

    // Key absent → use defaults. Empty list (user explicitly disabled) → empty
    // vec, which `china_dns::split_applies` reads as "skip orchestration".
    let china_upstreams = china.unwrap_or_else(crate::china_dns::default_china_upstreams);
    (urls, china_upstreams)
}

fn parse_china_upstreams(values: Vec<serde_yaml::Value>) -> Vec<std::net::SocketAddr> {
    let mut out = Vec::with_capacity(values.len());
    for entry in values {
        let serde_yaml::Value::String(raw) = entry else {
            continue;
        };
        // Accept "host" or "host:port"; assume UDP/53 when port omitted, matching
        // how upstream Clash/mihomo treats bare nameserver entries.
        let with_port = if raw.contains(':') {
            raw.clone()
        } else {
            format!("{}:53", raw)
        };
        match with_port.parse::<std::net::SocketAddr>() {
            Ok(addr) => {
                if !out.contains(&addr) {
                    out.push(addr);
                }
            }
            Err(e) => warn!(
                "china_dns: ignoring malformed dns.china_nameserver entry {:?}: {}",
                raw, e
            ),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// External cache hooks for `china_dns`.
//
// `china_dns` shares the same answer cache as the DoH path so that whichever
// upstream "won" a given (qname, qtype) query — Chinese UDP or trusted DoH —
// the next identical query within the TTL window short-circuits without
// re-running orchestration.
// ---------------------------------------------------------------------------

pub(crate) fn cache_lookup_for_external(query: &[u8]) -> Option<Vec<u8>> {
    let key = question_section(query)?;
    let now = Instant::now();
    let mut cache = cache().lock();
    let bytes = match cache.get(key) {
        Some((bytes, expires)) if *expires > now => bytes.clone(),
        Some(_) => {
            cache.remove(key);
            let owned = key.to_vec();
            drop(cache);
            doh_cache::remove(&owned);
            return None;
        }
        None => return None,
    };
    drop(cache);
    let mut resp = bytes;
    patch_txid(&mut resp, query);
    Some(resp)
}

pub(crate) fn cache_store_external(query: &[u8], response: &[u8]) {
    let Some(key) = question_section(query) else {
        return;
    };
    let key = key.to_vec();
    let ttl = cache_ttl(response);
    let expires_unix = doh_cache::unix_secs_in(ttl);
    let mut evicted: Option<Vec<u8>> = None;
    {
        let mut cache = cache().lock();
        if cache.len() >= CACHE_MAX_ENTRIES {
            if let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, (_, e))| *e)
                .map(|(k, _)| k.clone())
            {
                cache.remove(&oldest);
                evicted = Some(oldest);
            }
        }
        cache.insert(key.clone(), (response.to_vec(), Instant::now() + ttl));
    }
    if let Some(e) = evicted {
        doh_cache::remove(&e);
    }
    doh_cache::put(&key, response, expires_unix);
}
