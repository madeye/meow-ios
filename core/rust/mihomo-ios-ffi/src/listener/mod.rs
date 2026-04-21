//! Local loopback listener — ported from madeye/meow's Android FFI
//! (`core/src/main/rust/mihomo-android-ffi/src/listener/mod.rs`).
//!
//! The `MixedListener` binds on 127.0.0.1:<mixed-port> and dispatches each
//! accepted TCP connection either as SOCKS5 or as HTTP-proxy, matching
//! mihomo's "mixed" listener semantics. tun2socks opens SOCKS5 connections
//! to this listener for every TCP flow it accepts from netstack; DoH POSTs
//! reach it via reqwest's `socks5h://` proxy.
//!
//! Divergence from the Android reference: the iOS crate pins mihomo-rust
//! 0.4 (Android is on 0.3), so the per-flow dispatch goes through the
//! high-level `mihomo_tunnel::tcp::handle_tcp` entry point rather than the
//! 0.3-era `inner.resolve_proxy` / `proxy.dial_tcp` / manual stats tracking
//! path. Everything `handle_tcp` does internally — rule match, stats,
//! dial, bidirectional copy — is the same work the 0.3 listener did by
//! hand, and it matches what `tun2socks::run_tun2socks` already calls for
//! netstack-originated TCP flows, so the two code paths stay aligned.

pub mod http_proxy;
pub mod mixed;
pub mod socks5;

pub use mixed::MixedListener;

use mihomo_common::ProxyConn;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

/// `ProxyConn` wrapper for `tokio::net::TcpStream`. Required by the orphan
/// rule so `handle_tcp` can accept the client side of an accepted mixed-port
/// connection as a generic `Box<dyn ProxyConn>`. Mirrors the `NetstackConn`
/// wrapper `tun2socks.rs` uses for netstack streams.
pub(crate) struct TcpStreamConn(pub TcpStream);

impl AsyncRead for TcpStreamConn {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl AsyncWrite for TcpStreamConn {
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

impl ProxyConn for TcpStreamConn {
    fn remote_destination(&self) -> String {
        String::new()
    }
}
