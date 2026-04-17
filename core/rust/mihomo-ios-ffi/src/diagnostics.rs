//! Network diagnostics surfaced to the UI. Each function returns either a
//! success measurement or a human-readable error string — never panics.
use anyhow::{anyhow, Result};
use mihomo_proxy::health::{url_test, UrlTestError};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;

pub async fn test_direct_tcp(host: &str, port: u16, to: Duration) -> Result<Duration> {
    let target = format!("{}:{}", host, port);
    let start = Instant::now();
    let addrs: Vec<SocketAddr> = target.to_socket_addrs()?.collect();
    let addr = addrs.first().ok_or_else(|| anyhow!("no addresses for {}", host))?;
    timeout(to, TcpStream::connect(addr))
        .await
        .map_err(|_| anyhow!("connect timed out after {:?}", to))??;
    Ok(start.elapsed())
}

pub async fn test_proxy_http(
    tunnel: &mihomo_tunnel::Tunnel,
    url: &str,
    to: Duration,
) -> Result<(u16, Duration)> {
    let direct = tunnel.inner().direct.clone();
    let start = Instant::now();
    match url_test(direct.as_ref(), url, None, to).await {
        Ok(status) => Ok((status, start.elapsed())),
        Err(UrlTestError::Timeout) => Err(anyhow!("timed out after {:?}", to)),
        Err(UrlTestError::Transport(msg)) => Err(anyhow!(msg)),
    }
}

pub async fn test_dns(
    tunnel: &mihomo_tunnel::Tunnel,
    host: &str,
    to: Duration,
) -> Result<Vec<IpAddr>> {
    let resolver = tunnel.resolver().clone();
    let host = host.to_string();
    let result = timeout(to, async move {
        let mut out = Vec::new();
        if let Some(ip) = resolver.lookup_ipv4(&host).await {
            out.push(ip);
        }
        if let Some(ip) = resolver.lookup_ipv6(&host).await {
            out.push(ip);
        }
        out
    })
    .await
    .map_err(|_| anyhow!("DNS lookup timed out after {:?}", to))?;

    if result.is_empty() {
        Err(anyhow!("no records"))
    } else {
        Ok(result)
    }
}
