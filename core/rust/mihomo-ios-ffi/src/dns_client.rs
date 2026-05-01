//! Plain-TCP DNS client. Each query opens a `mihomo_tunnel::tcp::handle_tcp`
//! flow toward an upstream resolver (default 1.1.1.1:53 / 8.8.8.8:53), writes
//! the RFC 1035 length-prefixed message, then reads the length-prefixed
//! response. Same in-process Rust-to-Rust dispatch path the netstack TCP
//! flows take in `tun2socks::dispatch_tcp` — there is no loopback SOCKS
//! listener; mihomo sees the DNS bytes the same way it sees TUN-originated
//! TCP, so the proxy chain (selector → SOCKS5 outbound → upstream) is honored.

use crate::dns_table;
use crate::doh_cache;
use crate::engine;
use crate::logging;
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::OnceLock;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream, ReadBuf};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{info, warn};

const DNS_TIMEOUT_SECS: u64 = 5;
const DUPLEX_BUF_SIZE: usize = 16 * 1024;

const DEFAULT_UPSTREAMS: &[&str] = &["1.1.1.1:53", "8.8.8.8:53"];

// Answer cache: collapses duplicate in-flight queries — same rationale and
// shape as the prior DoH client. Keyed on the raw question section
// (name + qtype + qclass); txid is patched onto the cached response per
// request.
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
// N-1 mihomo flows + duplex pairs.
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
/// `handle_tcp` mihomo flow if `send_query` returns early (timeout, IO error)
/// instead of leaving it detached.
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

struct DnsClient {
    upstreams: Vec<SocketAddr>,
}

static DNS_CLIENT: OnceLock<DnsClient> = OnceLock::new();

/// User-configured upstreams written by `meow_dns_set_upstreams` (called from
/// the Swift settings layer before `meow_tun_start`). `None` (never set) and
/// `Some(empty)` both mean "fall back to built-in defaults".
static USER_UPSTREAMS: Mutex<Option<Vec<SocketAddr>>> = Mutex::new(None);

/// Replace the in-memory upstream list. Called from the FFI surface when the
/// user edits the DNS field in Settings. Takes effect on the next
/// `init_dns_client` (i.e. next `meow_tun_start`); already-resolved cache
/// entries persist.
pub fn set_user_upstreams(addrs: Vec<SocketAddr>) {
    *USER_UPSTREAMS.lock() = Some(addrs);
}

pub fn init_dns_client() {
    DNS_CLIENT.get_or_init(|| {
        let china_upstreams = read_china_upstreams();
        let upstreams = effective_upstreams();
        info!(
            "TCP DNS client (in-process dispatch): upstreams={:?}",
            upstreams
        );

        let home_dir_for_geoip = {
            let home_dir = crate::HOME_DIR.lock();
            doh_cache::init(home_dir.as_deref());
            home_dir.clone()
        };
        hydrate_in_memory_from_disk();

        // Wire the trust-china-dns split-horizon layer. Reads `Country.mmdb`
        // from the same `$HOME_DIR/mihomo/` path mihomo's engine uses; if the
        // file is missing the orchestrator quietly degrades to direct-only.
        crate::china_dns::init(home_dir_for_geoip.as_deref(), china_upstreams);

        DnsClient { upstreams }
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
    info!("dns cache: hydrated {} entries from disk", cache.len());
}

pub async fn resolve_via_tcp_dns(query: &[u8]) -> Option<Vec<u8>> {
    let client = DNS_CLIENT.get()?;

    let key = question_section(query).map(|q| q.to_vec());

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

    let result = run_attempts(client, query).await;

    if let (Some(k), Some(bytes)) = (key.as_ref(), result.as_ref()) {
        let ttl = cache_ttl(bytes);
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

async fn run_attempts(client: &DnsClient, query: &[u8]) -> Option<Vec<u8>> {
    for upstream in &client.upstreams {
        match tokio::time::timeout(
            Duration::from_secs(DNS_TIMEOUT_SECS),
            send_query(*upstream, query),
        )
        .await
        {
            Ok(Ok(bytes)) => return Some(bytes),
            Ok(Err(e)) => warn!("TCP DNS request failed to {}: {}", upstream, e),
            Err(_) => warn!("TCP DNS request timed out to {}", upstream),
        }
    }

    logging::bridge_log("DNS: all upstreams failed");
    None
}

/// One TCP DNS round-trip over a fresh mihomo flow: open duplex, hand the
/// far end to `handle_tcp`, write [u16 length][query], read [u16 length]
/// [response]. Connection is single-use — TCP-DNS pipelining (RFC 7766)
/// would require txid demux that the answer cache + single-flight already
/// obviates for the burst patterns we see.
async fn send_query(upstream: SocketAddr, query: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    let tunnel = engine::tunnel().ok_or_else(|| anyhow::anyhow!("engine not running"))?;

    // Mirror tun2socks::dispatch_tcp's metadata. Upstream is always an IP
    // literal here, so `dst_ip` is populated and `host` left empty —
    // mihomo doesn't try to re-resolve.
    let metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Inner,
        src_ip: None,
        src_port: 0,
        dst_ip: Some(upstream.ip()),
        dst_port: upstream.port(),
        host: String::new(),
        ..Default::default()
    };

    let (left, right) = tokio::io::duplex(DUPLEX_BUF_SIZE);
    let proxy_conn: Box<dyn ProxyConn> = Box::new(DuplexConn(right));
    let inner = tunnel.inner().clone();
    let _flow_guard = AbortOnDrop(tokio::spawn(async move {
        mihomo_tunnel::tcp::handle_tcp(&inner, proxy_conn, metadata).await;
    }));

    let mut stream = left;

    let qlen = u16::try_from(query.len()).map_err(|_| anyhow::anyhow!("DNS query too large"))?;
    let mut framed = Vec::with_capacity(2 + query.len());
    framed.extend_from_slice(&qlen.to_be_bytes());
    framed.extend_from_slice(query);
    stream.write_all(&framed).await?;
    stream.flush().await?;

    let mut len_buf = [0u8; 2];
    stream.read_exact(&mut len_buf).await?;
    let resp_len = u16::from_be_bytes(len_buf) as usize;
    if resp_len == 0 {
        anyhow::bail!("upstream returned zero-length response");
    }
    let mut resp = vec![0u8; resp_len];
    stream.read_exact(&mut resp).await?;
    // Best-effort half-close so the mihomo flow drains promptly. The abort
    // guard tears it down on drop regardless.
    let _ = stream.shutdown().await;
    Ok(resp)
}

/// `ProxyConn` requires the wrapper to be local (orphan rule), so we hand
/// mihomo this newtype around tokio's `DuplexStream`.
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

/// Built-in defaults used when the user has not configured any upstream in
/// the iOS Settings view (or when their input fails to parse).
fn default_upstreams() -> Vec<SocketAddr> {
    DEFAULT_UPSTREAMS
        .iter()
        .filter_map(|s| s.parse().ok())
        .collect()
}

/// Resolve the upstream list at `init_dns_client` time: prefer the user's
/// Settings-driven list (if any), otherwise fall back to the built-in
/// defaults (1.1.1.1 / 8.8.8.8). The trusted-resolver upstream pool is no
/// longer read from `config.yaml` — only the iOS Settings view writes it.
fn effective_upstreams() -> Vec<SocketAddr> {
    let user = USER_UPSTREAMS.lock().clone().unwrap_or_default();
    if !user.is_empty() {
        return user;
    }
    default_upstreams()
}

/// Parse a comma- or whitespace-separated list of upstream entries (`host`
/// or `host:port`, port defaults to 53) into a deduplicated `SocketAddr`
/// vector. Empty / whitespace-only input yields an empty vec.
pub(crate) fn parse_upstreams_csv(input: &str) -> Vec<SocketAddr> {
    let mut out: Vec<SocketAddr> = Vec::new();
    for raw in input.split(|c: char| c == ',' || c.is_whitespace()) {
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        // Drop legacy DoH/DoT/DoQ schemes — this client speaks plain TCP only.
        if raw.starts_with("https://")
            || raw.starts_with("tls://")
            || raw.starts_with("quic://")
            || raw.starts_with("h3://")
        {
            continue;
        }
        let stripped = raw
            .strip_prefix("tcp://")
            .or_else(|| raw.strip_prefix("dns://"))
            .unwrap_or(raw);
        let with_port = if stripped.contains(':') {
            stripped.to_string()
        } else {
            format!("{}:53", stripped)
        };
        match with_port.parse::<SocketAddr>() {
            Ok(addr) => {
                if !out.contains(&addr) {
                    out.push(addr);
                }
            }
            Err(e) => warn!("DNS: ignoring malformed upstream {:?}: {}", raw, e),
        }
    }
    out
}

#[derive(serde::Deserialize)]
struct MinimalConfig {
    dns: Option<MinimalDns>,
}

#[derive(serde::Deserialize)]
struct MinimalDns {
    /// `china_dns`-only field — Chinese plain-UDP nameservers, raced
    /// first-response-wins. `None` (key missing) → use built-in defaults
    /// (DNSPod + AliDNS). `Some(empty)` → disable the split entirely.
    china_nameserver: Option<Vec<serde_yaml::Value>>,
}

/// Reads `dns.china_nameserver` from `config.yaml` for the split-horizon
/// path. Returns the built-in defaults on any error or absence. The
/// trusted-resolver upstream pool is configured separately from the iOS
/// Settings view (`meow_dns_set_upstreams`), not from YAML.
fn read_china_upstreams() -> Vec<SocketAddr> {
    let home_dir = crate::HOME_DIR.lock();
    let config_path = match home_dir.as_ref() {
        Some(dir) => format!("{}/config.yaml", dir),
        None => return crate::china_dns::default_china_upstreams(),
    };
    drop(home_dir);

    let config_str = match std::fs::read_to_string(&config_path) {
        Ok(s) => s,
        Err(_) => return crate::china_dns::default_china_upstreams(),
    };

    let config: MinimalConfig = match serde_yaml::from_str(&config_str) {
        Ok(c) => c,
        Err(e) => {
            warn!("china_dns: cannot parse config: {}", e);
            return crate::china_dns::default_china_upstreams();
        }
    };

    config
        .dns
        .and_then(|d| d.china_nameserver)
        .map(parse_china_upstreams)
        .unwrap_or_else(crate::china_dns::default_china_upstreams)
}

fn parse_china_upstreams(values: Vec<serde_yaml::Value>) -> Vec<SocketAddr> {
    let mut out = Vec::with_capacity(values.len());
    for entry in values {
        let serde_yaml::Value::String(raw) = entry else {
            continue;
        };
        let with_port = if raw.contains(':') {
            raw.clone()
        } else {
            format!("{}:53", raw)
        };
        match with_port.parse::<SocketAddr>() {
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
// `china_dns` shares the same answer cache as the trusted-resolver path so
// that whichever upstream "won" a given (qname, qtype) query — Chinese UDP
// or trusted TCP DNS — the next identical query within the TTL window
// short-circuits without re-running orchestration.
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
