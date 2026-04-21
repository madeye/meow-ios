//! HTTP proxy handler for the mixed listener. Parses an HTTP/1.1 request
//! off an accepted TCP stream, handles both CONNECT (HTTPS tunneling) and
//! plain HTTP methods, builds a `Metadata`, then hands the stream to
//! `mihomo_tunnel::tcp::handle_tcp` for rule match + dial + copy.
//!
//! Request parsing is lifted verbatim from the madeye/meow Android FFI;
//! the dispatch tail uses mihomo-rust 0.4's high-level entry point so it
//! stays consistent with the SOCKS5 handler and `tun2socks.rs`.

use super::TcpStreamConn;
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use mihomo_tunnel::Tunnel;
use std::net::SocketAddr;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info};

/// HTTP request as parsed from the client side. Either CONNECT (tunnel the
/// raw stream after writing a 200) or a plain HTTP method (rewrite the
/// request line, forward it, then bidirectionally copy).
enum ParsedRequest {
    Connect {
        metadata: Metadata,
    },
    Plain {
        metadata: Metadata,
        rewritten: Vec<u8>,
    },
}

pub async fn handle_http(tunnel: &Tunnel, mut stream: TcpStream, src_addr: SocketAddr) {
    let parsed = match parse_request(&mut stream, src_addr).await {
        Ok(p) => p,
        Err(e) => {
            debug!("HTTP proxy error from {}: {}", src_addr, e);
            return;
        }
    };

    match parsed {
        ParsedRequest::Connect { metadata } => {
            info!(
                "HTTP CONNECT {} -> {}:{}",
                src_addr, metadata.host, metadata.dst_port,
            );
            if let Err(e) = stream
                .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                .await
            {
                debug!("CONNECT 200 write failed: {}", e);
                return;
            }
            let conn: Box<dyn ProxyConn> = Box::new(TcpStreamConn(stream));
            mihomo_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata).await;
        }
        ParsedRequest::Plain {
            metadata,
            rewritten,
        } => {
            info!(
                "HTTP {} -> {}:{}",
                src_addr, metadata.host, metadata.dst_port,
            );
            // For plain HTTP we need to send the rewritten request line +
            // headers into the remote first. We achieve that by wrapping the
            // client stream in a prefetching reader: we already consumed the
            // full header block out of `stream`, so the client has nothing
            // more pending until the upstream responds, but we do have to
            // push the rewritten bytes into the upstream. That's
            // `handle_tcp`'s job on the copy-up side if we can seed the
            // write half — however 0.4's `handle_tcp` treats its
            // `ProxyConn` as the client, not the upstream. So for plain
            // HTTP we'd need upstream-write-before-copy hooking that 0.4
            // doesn't expose. Until that gap closes, surface a 501 back
            // to the client so HTTP/non-CONNECT flows fail cleanly instead
            // of silently dropping bytes.
            let _ = rewritten;
            let _ = stream
                .write_all(b"HTTP/1.1 501 Not Implemented\r\n\r\n")
                .await;
            debug!(
                "HTTP proxy: plain (non-CONNECT) not supported via handle_tcp on mihomo 0.4",
            );
        }
    }
}

async fn parse_request(
    stream: &mut TcpStream,
    src_addr: SocketAddr,
) -> Result<ParsedRequest, Box<dyn std::error::Error + Send + Sync>> {
    // Read the HTTP request line and headers byte-by-byte until \r\n\r\n.
    let mut request_buf = Vec::with_capacity(4096);
    loop {
        let mut byte = [0u8; 1];
        let n = stream.read(&mut byte).await?;
        if n == 0 {
            return Err("connection closed before headers complete".into());
        }
        request_buf.push(byte[0]);
        if request_buf.len() >= 4 && request_buf[request_buf.len() - 4..] == *b"\r\n\r\n" {
            break;
        }
        if request_buf.len() > 8192 {
            return Err("request headers too large".into());
        }
    }

    let request_str = String::from_utf8_lossy(&request_buf);
    let request_line = request_str
        .lines()
        .next()
        .ok_or("empty request")?
        .to_string();

    let parts: Vec<&str> = request_line.split_whitespace().collect();
    if parts.len() < 3 {
        return Err("invalid HTTP request line".into());
    }
    let method = parts[0];
    let target = parts[1];

    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = parse_host_port(target, 443)?;
        let metadata = Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Https,
            src_ip: Some(src_addr.ip()),
            src_port: src_addr.port(),
            host: host.clone(),
            dst_port: port,
            ..Default::default()
        };
        Ok(ParsedRequest::Connect { metadata })
    } else {
        let url = target;
        let (host, port) = parse_url_host_port(url)?;
        let metadata = Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Http,
            src_ip: Some(src_addr.ip()),
            src_port: src_addr.port(),
            host: host.clone(),
            dst_port: port,
            ..Default::default()
        };

        let path = extract_path_from_url(url);
        let mut rewritten = format!("{} {} {}\r\n", method, path, parts[2]).into_bytes();
        for line in request_str.lines().skip(1) {
            if line.is_empty() {
                break;
            }
            let lower = line.to_ascii_lowercase();
            if lower.starts_with("proxy-connection") || lower.starts_with("proxy-authorization") {
                continue;
            }
            rewritten.extend_from_slice(line.as_bytes());
            rewritten.extend_from_slice(b"\r\n");
        }
        rewritten.extend_from_slice(b"\r\n");
        Ok(ParsedRequest::Plain {
            metadata,
            rewritten,
        })
    }
}

fn parse_host_port(
    target: &str,
    default_port: u16,
) -> Result<(String, u16), Box<dyn std::error::Error + Send + Sync>> {
    if let Some((host, port_str)) = target.rsplit_once(':') {
        if let Ok(port) = port_str.parse::<u16>() {
            return Ok((host.to_string(), port));
        }
    }
    Ok((target.to_string(), default_port))
}

fn parse_url_host_port(
    url: &str,
) -> Result<(String, u16), Box<dyn std::error::Error + Send + Sync>> {
    let without_scheme = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .unwrap_or(url);
    let authority = without_scheme.split('/').next().unwrap_or(without_scheme);
    let default_port = if url.starts_with("https://") { 443 } else { 80 };
    parse_host_port(authority, default_port)
}

fn extract_path_from_url(url: &str) -> &str {
    let without_scheme = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .unwrap_or(url);
    without_scheme
        .find('/')
        .map(|i| &without_scheme[i..])
        .unwrap_or("/")
}
