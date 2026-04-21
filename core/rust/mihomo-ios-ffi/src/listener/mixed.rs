//! Mixed (SOCKS5 + HTTP proxy) listener. Ported verbatim from the Android FFI.

use super::http_proxy;
use super::socks5;
use mihomo_tunnel::Tunnel;
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tracing::{debug, error, info};

pub struct MixedListener {
    tunnel: Tunnel,
    listen_addr: SocketAddr,
}

impl MixedListener {
    pub fn new(tunnel: Tunnel, listen_addr: SocketAddr) -> Self {
        Self {
            tunnel,
            listen_addr,
        }
    }

    pub async fn run(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let listener = TcpListener::bind(self.listen_addr).await?;
        info!("Mixed listener on {}", self.listen_addr);

        loop {
            let (stream, src_addr) = match listener.accept().await {
                Ok(v) => v,
                Err(e) => {
                    error!("Accept error: {}", e);
                    continue;
                }
            };

            let tunnel = self.tunnel.clone();
            tokio::spawn(async move {
                handle_connection(tunnel, stream, src_addr).await;
            });
        }
    }
}

async fn handle_connection(tunnel: Tunnel, stream: tokio::net::TcpStream, src_addr: SocketAddr) {
    // Peek the first byte to determine protocol.
    let mut peek = [0u8; 1];
    match stream.peek(&mut peek).await {
        Ok(0) => return,
        Ok(_) => {}
        Err(e) => {
            debug!("Peek error: {}", e);
            return;
        }
    }

    if peek[0] == 0x05 {
        socks5::handle_socks5(&tunnel, stream, src_addr).await;
    } else {
        http_proxy::handle_http(&tunnel, stream, src_addr).await;
    }
}
