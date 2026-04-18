//! DNS-over-HTTPS client. Each request runs over a `tokio::io::duplex` pair
//! whose far end is handed to `mihomo_tunnel::tcp::handle_tcp` — the same
//! in-process Rust-to-Rust dispatch path the netstack TCP flows take in
//! `tun2socks::dispatch_tcp`. There is no loopback SOCKS listener; mihomo
//! sees the TLS bytes the same way it sees TUN-originated TCP.

use crate::engine;
use crate::logging;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::client::conn::http1;
use hyper::header::{ACCEPT, CONTENT_TYPE, HOST};
use hyper::{Method, Request, Uri};
use hyper_util::rt::TokioIo;
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use std::io;
use std::pin::Pin;
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};
use tokio_rustls::TlsConnector;
use tracing::{info, warn};

const DOH_TIMEOUT_SECS: u64 = 5;
const DUPLEX_BUF_SIZE: usize = 64 * 1024;

const IP_BASED_DOH_URLS: &[&str] = &["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"];

struct DohClient {
    doh_urls: Vec<String>,
    tls_config: Arc<ClientConfig>,
}

static DOH_CLIENT: OnceLock<DohClient> = OnceLock::new();

pub fn init_doh_client() {
    DOH_CLIENT.get_or_init(|| {
        let doh_urls = read_doh_urls_from_config();
        info!("DoH client (in-process dispatch): urls={:?}", doh_urls);

        // The DoH path can traverse arbitrary upstream proxies the user
        // configured; matching the previous reqwest behavior, accept any
        // server cert. The DNS payload itself is not a secret and we trust
        // the proxy operator (i.e. the user).
        let tls_config = ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertVerify))
            .with_no_client_auth();

        DohClient {
            doh_urls,
            tls_config: Arc::new(tls_config),
        }
    });
}

pub async fn resolve_via_doh(query: &[u8]) -> Option<Vec<u8>> {
    let client = DOH_CLIENT.get()?;

    for url in &client.doh_urls {
        match tokio::time::timeout(
            Duration::from_secs(DOH_TIMEOUT_SECS),
            send_doh(client, url, query),
        )
        .await
        {
            Ok(Ok(bytes)) => return Some(bytes),
            Ok(Err(e)) => warn!("DoH request failed to {}: {}", url, e),
            Err(_) => warn!("DoH request timed out to {}", url),
        }
    }

    logging::bridge_log("DoH: all servers failed");
    None
}

async fn send_doh(client: &DohClient, url: &str, query: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    let uri: Uri = url.parse()?;
    let scheme = uri.scheme_str().unwrap_or("");
    if scheme != "https" {
        anyhow::bail!("non-https DoH URL: {}", url);
    }
    let host = uri
        .host()
        .ok_or_else(|| anyhow::anyhow!("URL missing host"))?
        .to_string();
    let port = uri.port_u16().unwrap_or(443);
    let authority = uri
        .authority()
        .ok_or_else(|| anyhow::anyhow!("URL missing authority"))?
        .as_str()
        .to_string();

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
        host: if dst_ip.is_some() { String::new() } else { host.clone() },
        ..Default::default()
    };

    let (left, right) = tokio::io::duplex(DUPLEX_BUF_SIZE);
    let proxy_conn: Box<dyn ProxyConn> = Box::new(DuplexConn(right));
    let inner = tunnel.inner().clone();
    tokio::spawn(async move {
        mihomo_tunnel::tcp::handle_tcp(&inner, proxy_conn, metadata).await;
    });

    let server_name = ServerName::try_from(host.clone())?;
    let tls_stream = TlsConnector::from(client.tls_config.clone())
        .connect(server_name, left)
        .await?;

    let (mut sender, conn) = http1::handshake(TokioIo::new(tls_stream)).await?;
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            warn!("DoH connection driver error: {}", e);
        }
    });

    let req = Request::builder()
        .method(Method::POST)
        .uri(&uri)
        .header(HOST, authority.as_str())
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
}

fn read_doh_urls_from_config() -> Vec<String> {
    let home_dir = crate::HOME_DIR.lock();
    let config_path = match home_dir.as_ref() {
        Some(dir) => format!("{}/config.yaml", dir),
        None => {
            info!("DoH: no HOME_DIR, using default URL");
            return IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect();
        }
    };
    drop(home_dir);

    let config_str = match std::fs::read_to_string(&config_path) {
        Ok(s) => s,
        Err(e) => {
            warn!("DoH: cannot read {}: {}", config_path, e);
            return IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect();
        }
    };

    let config: MinimalConfig = match serde_yaml::from_str(&config_str) {
        Ok(c) => c,
        Err(e) => {
            warn!("DoH: cannot parse config: {}", e);
            return IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect();
        }
    };

    let mut urls = Vec::new();
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
    }

    for fallback in IP_BASED_DOH_URLS {
        let s = fallback.to_string();
        if !urls.contains(&s) {
            urls.push(s);
        }
    }

    urls
}
