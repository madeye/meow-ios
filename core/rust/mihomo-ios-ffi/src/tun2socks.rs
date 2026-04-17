//! tun2socks using netstack-smoltcp: reads raw IP packets from the Android TUN fd,
//! routes TCP through a userspace TCP/IP stack (smoltcp) and forwards via SOCKS5
//! to the local mihomo mixed listener. UDP DNS is handled via DoH.

use crate::dns_table;
use crate::doh_client;
use crate::logging;
use futures::{SinkExt, StreamExt};
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::os::raw::c_void;
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, info};

use netstack_smoltcp::{AnyIpPktFrame, StackBuilder};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

static TUN2SOCKS_RUNNING: AtomicBool = AtomicBool::new(false);

pub fn start(fd: i32, socks_port: u16, _dns_port: u16) -> Result<(), String> {
    if TUN2SOCKS_RUNNING.swap(true, Ordering::SeqCst) {
        return Err("tun2socks already running".into());
    }

    let socks_addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, socks_port));
    info!("tun2socks starting: fd={}, socks={}", fd, socks_addr);
    doh_client::init_doh_client(socks_port);

    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let rt = crate::get_runtime();
    rt.spawn(async move {
        if let Err(e) = run_tun2socks(fd, socks_addr).await {
            logging::bridge_log(&format!("tun2socks error: {}", e));
        }
        TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
        info!("tun2socks exited");
    });

    Ok(())
}

pub fn stop() {
    TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
}

// ---------------------------------------------------------------------------
// Main tun2socks loop
//
// Key design: the Stack is NOT split. It implements both Sink (ingress) and
// Stream (egress). futures::SplitSink/SplitStream use a BiLock that prevents
// concurrent use — causing deadlocks when ingress and egress run on separate
// tasks. Instead, the TUN reader feeds packets via an mpsc channel to a single
// "stack driver" task that owns the Stack and multiplexes both directions.
// ---------------------------------------------------------------------------

async fn run_tun2socks(fd: RawFd, socks_addr: SocketAddr) -> io::Result<()> {
    logging::bridge_log("tun2socks: building netstack-smoltcp stack");

    let (mut stack, tcp_runner, _udp_socket, tcp_listener) = StackBuilder::default()
        .enable_tcp(true)
        .enable_udp(false)
        .stack_buffer_size(1024)
        .tcp_buffer_size(512)
        .build()?;

    let tcp_runner = tcp_runner.expect("TCP runner");
    let mut tcp_listener = tcp_listener.expect("TCP listener");

    logging::bridge_log("tun2socks: starting tasks");

    // Channel: TUN reader → stack driver (ingress packets)
    let (ingress_tx, mut ingress_rx) = mpsc::channel::<AnyIpPktFrame>(256);

    // Channel: stack driver + UDP replies → TUN writer (egress packets)
    let (egress_tx, mut egress_rx) = mpsc::unbounded_channel::<Vec<u8>>();

    // Task 1: TCP runner (smoltcp internal polling)
    let runner_handle = tokio::spawn(async move {
        if let Err(e) = tcp_runner.await {
            logging::bridge_log(&format!("tun2socks: TCP runner error: {}", e));
        }
    });

    // Task 2: Stack driver — single owner of Stack, no split
    let egress_tx2 = egress_tx.clone();
    let stack_handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                // Ingress: receive packet from TUN reader, send to stack
                pkt = ingress_rx.recv() => {
                    match pkt {
                        Some(frame) => {
                            if let Err(e) = stack.send(frame).await {
                                logging::bridge_log(&format!("stack send error: {}", e));
                                break;
                            }
                        }
                        None => break, // channel closed
                    }
                }
                // Egress: receive packet from stack, send to TUN writer
                pkt = stack.next() => {
                    match pkt {
                        Some(Ok(frame)) => { let _ = egress_tx2.send(frame); }
                        Some(Err(e)) => {
                            logging::bridge_log(&format!("stack recv error: {}", e));
                            break;
                        }
                        None => break,
                    }
                }
            }
        }
    });

    // Task 3: Accept TCP connections → SOCKS5 relay
    let tcp_accept_handle = tokio::spawn(async move {
        while let Some((stream, local_addr, remote_addr)) = tcp_listener.next().await {
            let sa = socks_addr;
            logging::bridge_log(&format!("tun2socks: TCP {} -> {}", local_addr, remote_addr));
            tokio::spawn(async move {
                handle_tcp_stream(stream, local_addr, remote_addr, sa).await;
            });
        }
    });

    // Task 4: TUN fd writer
    let tun_writer_handle = tokio::spawn(async move {
        while let Some(pkt) = egress_rx.recv().await {
            let mut retries = 0u32;
            loop {
                let written = unsafe { libc::write(fd, pkt.as_ptr() as *const c_void, pkt.len()) };
                if written >= 0 {
                    break;
                }
                let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if errno == libc::EAGAIN && retries < 3 {
                    retries += 1;
                    tokio::task::yield_now().await;
                    continue;
                }
                break;
            }
        }
    });

    // Task 5: TUN fd reader
    let udp_reply_tx = egress_tx.clone();
    let tun_reader_handle = tokio::spawn(async move {
        let mut read_buf = vec![0u8; 65535];
        let mut _pkt_total: u64 = 0;
        let mut _pkt_udp: u64 = 0;

        loop {
            if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
                break;
            }

            // Poll non-blocking fd with short yield
            tokio::task::yield_now().await;

            let mut did_work = false;
            loop {
                let n =
                    unsafe { libc::read(fd, read_buf.as_mut_ptr() as *mut c_void, read_buf.len()) };
                if n <= 0 {
                    break;
                }
                did_work = true;
                let n = n as usize;
                _pkt_total += 1;
                let ip_data = &read_buf[..n];

                // Intercept UDP DNS
                if let Some((src_ip, src_port, dst_ip, dst_port, payload)) =
                    parse_udp_packet(ip_data)
                {
                    if dst_port == 53 {
                        _pkt_udp += 1;
                        let reply_tx = udp_reply_tx.clone();
                        let query = payload.to_vec();
                        tokio::spawn(async move {
                            handle_dns_query(src_ip, src_port, dst_ip, dst_port, query, reply_tx)
                                .await;
                        });
                        continue;
                    }
                }

                // Send to stack for TCP processing (non-blocking try_send to avoid stall)
                let frame: AnyIpPktFrame = ip_data.to_vec();
                match ingress_tx.try_send(frame) {
                    Ok(()) => {}
                    Err(mpsc::error::TrySendError::Full(frame)) => {
                        // Channel full — block briefly to let stack drain
                        let _ = ingress_tx.send(frame).await;
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => break,
                }
            }

            if !did_work {
                // No packets available — sleep briefly to avoid busy-loop
                tokio::time::sleep(tokio::time::Duration::from_micros(200)).await;
            }
        }
    });

    // Wait for reader to finish (it checks TUN2SOCKS_RUNNING)
    let _ = tun_reader_handle.await;

    runner_handle.abort();
    stack_handle.abort();
    tcp_accept_handle.abort();
    tun_writer_handle.abort();

    logging::bridge_log("tun2socks: exiting");
    Ok(())
}

// ---------------------------------------------------------------------------
// TCP → SOCKS5 relay
// ---------------------------------------------------------------------------

async fn handle_tcp_stream(
    mut tun_stream: netstack_smoltcp::TcpStream,
    src_addr: SocketAddr,
    dst_addr: SocketAddr,
    socks_addr: SocketAddr,
) {
    let target = match dns_table::dns_table_lookup(dst_addr.ip()) {
        Some(hostname) => SocksTarget::Domain(hostname, dst_addr.port()),
        None => SocksTarget::Ip(dst_addr),
    };

    let target_desc = match &target {
        SocksTarget::Domain(h, p) => format!("{}:{}", h, p),
        SocksTarget::Ip(a) => format!("{}", a),
    };
    logging::bridge_log(&format!("SOCKS5 connect: {} -> {}", src_addr, target_desc));

    let mut socks_stream = match socks5_connect(socks_addr, target).await {
        Ok(s) => s,
        Err(e) => {
            logging::bridge_log(&format!(
                "SOCKS5 FAIL: {} -> {} err={}",
                src_addr, dst_addr, e
            ));
            return;
        }
    };

    match tokio::io::copy_bidirectional(&mut tun_stream, &mut socks_stream).await {
        Ok((up, down)) => {
            debug!("TCP relay done: {} up={} down={}", dst_addr, up, down);
        }
        Err(e) => {
            debug!("TCP relay error: {} err={}", dst_addr, e);
        }
    }
}

// ---------------------------------------------------------------------------
// SOCKS5 client
// ---------------------------------------------------------------------------

enum SocksTarget {
    Ip(SocketAddr),
    Domain(String, u16),
}

async fn socks5_connect(proxy: SocketAddr, target: SocksTarget) -> io::Result<TcpStream> {
    let mut stream = TcpStream::connect(proxy).await?;

    stream.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut resp = [0u8; 2];
    stream.read_exact(&mut resp).await?;
    if resp[0] != 0x05 || resp[1] != 0x00 {
        return Err(io::Error::other("SOCKS5 auth failed"));
    }

    match &target {
        SocksTarget::Ip(dst) => match dst {
            SocketAddr::V4(v4) => {
                let ip = v4.ip().octets();
                let port = v4.port().to_be_bytes();
                stream
                    .write_all(&[
                        0x05, 0x01, 0x00, 0x01, ip[0], ip[1], ip[2], ip[3], port[0], port[1],
                    ])
                    .await?;
            }
            SocketAddr::V6(v6) => {
                let mut req = vec![0x05, 0x01, 0x00, 0x04];
                req.extend_from_slice(&v6.ip().octets());
                req.extend_from_slice(&v6.port().to_be_bytes());
                stream.write_all(&req).await?;
            }
        },
        SocksTarget::Domain(domain, port) => {
            let db = domain.as_bytes();
            let mut req = Vec::with_capacity(4 + 1 + db.len() + 2);
            req.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, db.len() as u8]);
            req.extend_from_slice(db);
            req.extend_from_slice(&port.to_be_bytes());
            stream.write_all(&req).await?;
        }
    }

    let mut rh = [0u8; 4];
    stream.read_exact(&mut rh).await?;
    if rh[0] != 0x05 || rh[1] != 0x00 {
        return Err(io::Error::other(format!(
            "SOCKS5 CONNECT failed: rep={}",
            rh[1]
        )));
    }
    match rh[3] {
        0x01 => {
            let mut b = [0u8; 6];
            stream.read_exact(&mut b).await?;
        }
        0x03 => {
            let mut l = [0u8; 1];
            stream.read_exact(&mut l).await?;
            let mut b = vec![0u8; l[0] as usize + 2];
            stream.read_exact(&mut b).await?;
        }
        0x04 => {
            let mut b = [0u8; 18];
            stream.read_exact(&mut b).await?;
        }
        _ => {}
    }
    Ok(stream)
}

// ---------------------------------------------------------------------------
// UDP helpers
// ---------------------------------------------------------------------------

fn parse_udp_packet(ip_data: &[u8]) -> Option<(u32, u16, u32, u16, &[u8])> {
    if ip_data.len() < 28 {
        return None;
    }
    if (ip_data[0] >> 4) != 4 {
        return None;
    }
    if ip_data[9] != 17 {
        return None;
    }
    let ihl = (ip_data[0] & 0x0F) as usize * 4;
    if ip_data.len() < ihl + 8 {
        return None;
    }
    let src_ip = u32::from_ne_bytes([ip_data[12], ip_data[13], ip_data[14], ip_data[15]]);
    let dst_ip = u32::from_ne_bytes([ip_data[16], ip_data[17], ip_data[18], ip_data[19]]);
    let src_port = u16::from_be_bytes([ip_data[ihl], ip_data[ihl + 1]]);
    let dst_port = u16::from_be_bytes([ip_data[ihl + 2], ip_data[ihl + 3]]);
    let udp_len = u16::from_be_bytes([ip_data[ihl + 4], ip_data[ihl + 5]]) as usize;
    let start = ihl + 8;
    let end = (ihl + udp_len).min(ip_data.len());
    if start > end {
        return None;
    }
    Some((src_ip, src_port, dst_ip, dst_port, &ip_data[start..end]))
}

fn build_udp_packet(
    src_ip: u32,
    src_port: u16,
    dst_ip: u32,
    dst_port: u16,
    payload: &[u8],
) -> Vec<u8> {
    let udp_len = 8 + payload.len();
    let total_len = 20 + udp_len;
    let mut p = vec![0u8; total_len];
    p[0] = 0x45;
    p[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
    p[6] = 0x40;
    p[8] = 64;
    p[9] = 17;
    p[12..16].copy_from_slice(&src_ip.to_ne_bytes());
    p[16..20].copy_from_slice(&dst_ip.to_ne_bytes());
    let ck = ip_checksum(&p[..20]);
    p[10..12].copy_from_slice(&ck.to_be_bytes());
    p[20..22].copy_from_slice(&src_port.to_be_bytes());
    p[22..24].copy_from_slice(&dst_port.to_be_bytes());
    p[24..26].copy_from_slice(&(udp_len as u16).to_be_bytes());
    p[28..].copy_from_slice(payload);
    p
}

fn ip_checksum(h: &[u8]) -> u16 {
    let mut s: u32 = 0;
    for i in (0..h.len()).step_by(2) {
        s += if i + 1 < h.len() {
            (h[i] as u32) << 8 | h[i + 1] as u32
        } else {
            (h[i] as u32) << 8
        };
    }
    while s >> 16 != 0 {
        s = (s & 0xFFFF) + (s >> 16);
    }
    !s as u16
}

async fn handle_dns_query(
    src_ip: u32,
    src_port: u16,
    dst_ip: u32,
    dst_port: u16,
    query: Vec<u8>,
    reply_tx: mpsc::UnboundedSender<Vec<u8>>,
) {
    let name = dns_table::parse_dns_query_name(&query).unwrap_or_default();
    logging::bridge_log(&format!(
        "DoH: {} from {:?}:{}",
        name,
        Ipv4Addr::from(src_ip.to_ne_bytes()),
        src_port
    ));

    if let Some(response) = doh_client::resolve_via_doh(&query).await {
        for (ip, hostname, ttl) in dns_table::parse_dns_response_records(&response) {
            dns_table::dns_table_insert(ip, hostname, ttl);
        }
        let _ = reply_tx.send(build_udp_packet(
            dst_ip, dst_port, src_ip, src_port, &response,
        ));
    }
}
