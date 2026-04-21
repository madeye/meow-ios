//! SOCKS5 protocol handler for the mixed listener. Parses the SOCKS5
//! handshake off an accepted TCP stream, builds a `Metadata`, then hands
//! the post-handshake stream to `mihomo_tunnel::tcp::handle_tcp` which
//! performs rule match → proxy dial → bidirectional copy → stats tracking.
//!
//! The protocol parsing is lifted verbatim from the madeye/meow Android FFI;
//! the dispatch tail is adapted to mihomo-rust 0.4's high-level entry point
//! (see `listener/mod.rs` for why).

use super::TcpStreamConn;
use mihomo_common::{ConnType, Metadata, Network, ProxyConn};
use mihomo_tunnel::Tunnel;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info};

const SOCKS5_VERSION: u8 = 0x05;
const NO_AUTH: u8 = 0x00;
const CMD_CONNECT: u8 = 0x01;
#[allow(dead_code)]
const CMD_UDP_ASSOCIATE: u8 = 0x03;
const ATYP_IPV4: u8 = 0x01;
const ATYP_DOMAIN: u8 = 0x03;
const ATYP_IPV6: u8 = 0x04;
const REP_SUCCESS: u8 = 0x00;

pub async fn handle_socks5(tunnel: &Tunnel, mut stream: TcpStream, src_addr: SocketAddr) {
    match handshake(&mut stream, src_addr).await {
        Ok(Some(metadata)) => {
            info!(
                "SOCKS5 {} -> {}:{} (host={:?})",
                src_addr,
                metadata
                    .dst_ip
                    .map(|ip| ip.to_string())
                    .unwrap_or_else(|| "<domain>".into()),
                metadata.dst_port,
                metadata.host,
            );
            let conn: Box<dyn ProxyConn> = Box::new(TcpStreamConn(stream));
            mihomo_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata).await;
        }
        Ok(None) => {} // Non-CONNECT command; reply already sent.
        Err(e) => debug!("SOCKS5 error from {}: {}", src_addr, e),
    }
}

/// Parse the SOCKS5 greeting + request, answer the client, and return the
/// connection `Metadata` ready for dispatch. Returns `Ok(None)` if the
/// command wasn't CONNECT (we replied "command not supported").
async fn handshake(
    stream: &mut TcpStream,
    src_addr: SocketAddr,
) -> Result<Option<Metadata>, Box<dyn std::error::Error + Send + Sync>> {
    // Version/method negotiation.
    let mut header = [0u8; 2];
    stream.read_exact(&mut header).await?;
    if header[0] != SOCKS5_VERSION {
        return Err("invalid SOCKS version".into());
    }
    let nmethods = header[1] as usize;
    let mut methods = vec![0u8; nmethods];
    stream.read_exact(&mut methods).await?;
    stream.write_all(&[SOCKS5_VERSION, NO_AUTH]).await?;

    // Request.
    let mut req = [0u8; 4];
    stream.read_exact(&mut req).await?;
    if req[0] != SOCKS5_VERSION {
        return Err("invalid SOCKS version in request".into());
    }
    let cmd = req[1];
    let atyp = req[3];
    let (host, dst_ip, dst_port) = parse_socks5_address(stream, atyp).await?;

    if cmd != CMD_CONNECT {
        let reply = [SOCKS5_VERSION, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
        stream.write_all(&reply).await?;
        return Ok(None);
    }

    // Success reply with a dummy bind addr; the client only cares about rep=0.
    let reply = [
        SOCKS5_VERSION,
        REP_SUCCESS,
        0x00,
        ATYP_IPV4,
        0,
        0,
        0,
        0,
        0,
        0,
    ];
    stream.write_all(&reply).await?;

    Ok(Some(Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Socks5,
        src_ip: Some(src_addr.ip()),
        src_port: src_addr.port(),
        dst_ip,
        dst_port,
        host,
        ..Default::default()
    }))
}

async fn parse_socks5_address(
    stream: &mut TcpStream,
    atyp: u8,
) -> Result<(String, Option<IpAddr>, u16), Box<dyn std::error::Error + Send + Sync>> {
    match atyp {
        ATYP_IPV4 => {
            let mut addr = [0u8; 4];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let ip = IpAddr::V4(Ipv4Addr::new(addr[0], addr[1], addr[2], addr[3]));
            let port = u16::from_be_bytes(port_buf);
            Ok((String::new(), Some(ip), port))
        }
        ATYP_DOMAIN => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut domain = vec![0u8; len[0] as usize];
            stream.read_exact(&mut domain).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let host = String::from_utf8_lossy(&domain).to_string();
            let port = u16::from_be_bytes(port_buf);
            Ok((host, None, port))
        }
        ATYP_IPV6 => {
            let mut addr = [0u8; 16];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let ip = IpAddr::V6(Ipv6Addr::from(addr));
            let port = u16::from_be_bytes(port_buf);
            Ok((String::new(), Some(ip), port))
        }
        _ => Err(format!("unsupported address type: {}", atyp).into()),
    }
}
