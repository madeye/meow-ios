//! End-to-end Rust diagnostic for connection issues visiting
//! `https://www.xiaohongshu.com` through the meow-ios native stack.
//!
//! "Rust-only" — no Xcode, no iPhone, no `sudo`, no `utun`. We drive the
//! exact same C-ABI surface the iOS `PacketTunnelProvider` calls
//! (`meow_core_init`, `meow_core_set_home_dir`, `meow_engine_start`,
//! `meow_tun_start`, `meow_tun_ingest`) and substitute a Rust egress
//! callback for the Swift `NEPacketTunnelFlow.writePackets` sink. Every
//! byte that flows through the engine, the fake-IP DNS handler, the
//! `netstack-smoltcp` stack, and the in-process `mihomo_tunnel` dispatch
//! is the same code the device runs.
//!
//! What this surfaces:
//!
//!   * DNS layer — does the in-TUN UDP/53 intercept answer at all? Does
//!     the CN-bypass probe return a real CN address for `xiaohongshu.com`,
//!     or does it fall through to a `28.x.x.x` fake-IP?
//!   * DNS upstream-shopping — per-nameserver direct UDP/53 probes (not
//!     `getaddrinfo`!) against each pinned upstream (`119.29.29.29`,
//!     `223.5.5.5`, `1.1.1.1`). xiaohongshu.com has split-horizon DNS:
//!     CN-side resolvers return a CN PoP (`81.69.116.x`), Cloudflare /
//!     anycast resolvers return a SG / HK PoP (`43.175.7.x`). The
//!     test box's OS resolver may add its own twist on top.
//!   * TCP layer — does the netstack accept the SYN, does `dispatch_tcp`
//!     successfully route the flow, and does the upstream actually
//!     answer a TLS ClientHello with `Host: www.xiaohongshu.com`?
//!
//! Run with:
//!
//!     cargo test --test xhs_e2e -- --nocapture
//!
//! Skipped (with a log line, not a test failure) when the host has no
//! egress to the public Internet — the test needs to actually reach
//! Tencent/Alibaba DNS for the CN-bypass probe to do its job.

#![allow(unsafe_code)]

use std::ffi::CString;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};
use std::os::raw::c_void;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use mihomo_ios_ffi::{
    meow_core_init, meow_core_last_error, meow_core_set_home_dir, meow_engine_start,
    meow_engine_stop, meow_engine_test_direct_tcp, meow_engine_test_dns, meow_tun_ingest,
    meow_tun_start, meow_tun_stop,
};

// ---------------------------------------------------------------------------
// Egress capture
//
// The FFI's egress callback is a plain `extern "C" fn` — no closure
// environment. We stash a process-wide channel sender behind a `Mutex` and
// look it up from inside the trampoline. The test is single-threaded
// (`cargo test --test xhs_e2e` runs each integration test in its own
// process, and only one `#[test]` lives in this file) so a single
// global is fine and matches how the macos-utun-harness handles the same
// constraint.
// ---------------------------------------------------------------------------

static EGRESS_TX: Mutex<Option<mpsc::Sender<Vec<u8>>>> = Mutex::new(None);

unsafe extern "C" fn egress_trampoline(_ctx: *mut c_void, data: *const u8, len: usize) {
    if data.is_null() || len == 0 {
        return;
    }
    let slice = std::slice::from_raw_parts(data, len);
    let pkt = slice.to_vec();
    if let Some(tx) = EGRESS_TX.lock().ok().and_then(|g| g.clone()) {
        let _ = tx.send(pkt);
    }
}

fn last_ffi_error() -> String {
    let p = meow_core_last_error();
    if p.is_null() {
        return "<no error reported>".into();
    }
    unsafe { std::ffi::CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned()
}

// ---------------------------------------------------------------------------
// Packet builders — IPv4 + UDP for the DNS query, IPv4 + TCP SYN for the
// optional layer-4 probe. The egress side is parsed inline below.
// ---------------------------------------------------------------------------

fn ipv4_header_checksum(header: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for chunk in header.chunks_exact(2) {
        sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

/// Pseudo-header sum (RFC 793, modernized) used by both TCP and the
/// optional UDP-with-checksum path. We don't need it for our DNS query
/// (the responder accepts UDP checksum=0) but we *do* need it for TCP.
fn pseudo_header_sum(src: [u8; 4], dst: [u8; 4], proto: u8, len: u16) -> u32 {
    let mut sum: u32 = 0;
    sum += u32::from(u16::from_be_bytes([src[0], src[1]]));
    sum += u32::from(u16::from_be_bytes([src[2], src[3]]));
    sum += u32::from(u16::from_be_bytes([dst[0], dst[1]]));
    sum += u32::from(u16::from_be_bytes([dst[2], dst[3]]));
    sum += u32::from(proto);
    sum += u32::from(len);
    sum
}

fn fold_checksum(mut sum: u32) -> u16 {
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

fn build_ipv4_udp(
    src: [u8; 4],
    dst: [u8; 4],
    src_port: u16,
    dst_port: u16,
    payload: &[u8],
) -> Vec<u8> {
    let total_len = 20u16 + 8 + payload.len() as u16;
    let udp_len = 8u16 + payload.len() as u16;
    let mut pkt = Vec::with_capacity(total_len as usize);
    // IPv4 header.
    pkt.push(0x45);
    pkt.push(0x00);
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]);
    pkt.extend_from_slice(&[0x40, 0x00]);
    pkt.push(64);
    pkt.push(17);
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder
    pkt.extend_from_slice(&src);
    pkt.extend_from_slice(&dst);
    let ck = ipv4_header_checksum(&pkt[..20]);
    pkt[10..12].copy_from_slice(&ck.to_be_bytes());
    // UDP header.
    pkt.extend_from_slice(&src_port.to_be_bytes());
    pkt.extend_from_slice(&dst_port.to_be_bytes());
    pkt.extend_from_slice(&udp_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]); // UDP checksum=0 (RFC 768, legal on IPv4)
    pkt.extend_from_slice(payload);
    pkt
}

fn build_ipv4_tcp_syn(
    src: [u8; 4],
    dst: [u8; 4],
    src_port: u16,
    dst_port: u16,
    seq: u32,
) -> Vec<u8> {
    // 20 byte IP + 20 byte TCP header, no options, no data, SYN flag set.
    let total_len: u16 = 40;
    let mut pkt = Vec::with_capacity(total_len as usize);
    // IPv4.
    pkt.push(0x45);
    pkt.push(0x00);
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&[0x00, 0x01]); // identification
    pkt.extend_from_slice(&[0x40, 0x00]); // DF
    pkt.push(64);
    pkt.push(6); // TCP
    pkt.extend_from_slice(&[0, 0]); // header checksum placeholder
    pkt.extend_from_slice(&src);
    pkt.extend_from_slice(&dst);
    let ck = ipv4_header_checksum(&pkt[..20]);
    pkt[10..12].copy_from_slice(&ck.to_be_bytes());
    // TCP header — 20 bytes.
    pkt.extend_from_slice(&src_port.to_be_bytes());
    pkt.extend_from_slice(&dst_port.to_be_bytes());
    pkt.extend_from_slice(&seq.to_be_bytes());
    pkt.extend_from_slice(&0u32.to_be_bytes()); // ack
    pkt.push(0x50); // data offset = 5, reserved = 0
    pkt.push(0x02); // SYN
    pkt.extend_from_slice(&65535u16.to_be_bytes()); // window
    pkt.extend_from_slice(&[0, 0]); // tcp checksum placeholder
    pkt.extend_from_slice(&[0, 0]); // urgent
                                    // Compute TCP checksum.
    let tcp_len = (pkt.len() - 20) as u16;
    let mut sum = pseudo_header_sum(src, dst, 6, tcp_len);
    for chunk in pkt[20..].chunks(2) {
        if chunk.len() == 2 {
            sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
        } else {
            sum += u32::from(u16::from_be_bytes([chunk[0], 0]));
        }
    }
    let ck = fold_checksum(sum);
    pkt[36..38].copy_from_slice(&ck.to_be_bytes());
    pkt
}

// ---------------------------------------------------------------------------
// Tiny DNS query / response (just enough for A records — hickory is a
// regular crate dep, but using it from the integration test would force
// pulling in heavy resolver features the FFI doesn't expose. Hand-rolling
// the 12-byte header + qname encoding + 4-byte A record parse is shorter).
// ---------------------------------------------------------------------------

fn dns_a_query(qname: &str, id: u16) -> Vec<u8> {
    let mut out = Vec::with_capacity(64);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&0x0100u16.to_be_bytes()); // RD=1
    out.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // ANCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
    for label in qname.split('.').filter(|s| !s.is_empty()) {
        assert!(label.len() < 64);
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0); // root label
    out.extend_from_slice(&1u16.to_be_bytes()); // QTYPE=A
    out.extend_from_slice(&1u16.to_be_bytes()); // QCLASS=IN
    out
}

/// Advance `p` past one wire-format DNS name in `msg`. Handles uncompressed
/// labels, the all-zero root terminator, and compressed pointers (2-byte).
/// Returns the new offset, or `None` if the encoding ran off the end.
fn skip_name(msg: &[u8], mut p: usize) -> Option<usize> {
    loop {
        if p >= msg.len() {
            return None;
        }
        let b = msg[p];
        if b == 0 {
            return Some(p + 1);
        }
        if b & 0xC0 == 0xC0 {
            // Compressed pointer: 2 bytes, name ends right here.
            if p + 2 > msg.len() {
                return None;
            }
            return Some(p + 2);
        }
        let n = b as usize;
        p = p.checked_add(1 + n)?;
    }
}

/// Walk a DNS response and pull out A-record IPv4 addresses. Returns
/// `(rcode, ips)`. Best-effort: returns `(0xFF, vec![])` if the message
/// is unparseable. We log enough context that an empty-but-NOERROR
/// reply is debuggable from the test output rather than requiring a
/// pcap.
fn parse_dns_a_response(msg: &[u8]) -> (u8, Vec<[u8; 4]>) {
    if msg.len() < 12 {
        return (0xFF, vec![]);
    }
    let flags = u16::from_be_bytes([msg[2], msg[3]]);
    let rcode = (flags & 0x000F) as u8;
    let qd = u16::from_be_bytes([msg[4], msg[5]]) as usize;
    let an = u16::from_be_bytes([msg[6], msg[7]]) as usize;
    let mut p = 12usize;
    for _ in 0..qd {
        let Some(next) = skip_name(msg, p) else {
            return (rcode, vec![]);
        };
        p = next + 4; // QTYPE + QCLASS
    }
    let mut ips = Vec::new();
    for _ in 0..an {
        let Some(after_name) = skip_name(msg, p) else {
            break;
        };
        p = after_name;
        if p + 10 > msg.len() {
            break;
        }
        let rrtype = u16::from_be_bytes([msg[p], msg[p + 1]]);
        let rdlen = u16::from_be_bytes([msg[p + 8], msg[p + 9]]) as usize;
        p += 10;
        if p + rdlen > msg.len() {
            break;
        }
        if rrtype == 1 && rdlen == 4 {
            ips.push([msg[p], msg[p + 1], msg[p + 2], msg[p + 3]]);
        }
        p += rdlen;
    }
    (rcode, ips)
}

// ---------------------------------------------------------------------------
// Home-dir setup. Mirrors the AppGroup layout the device produces.
// ---------------------------------------------------------------------------

fn write_min_config(dir: &Path) -> PathBuf {
    let yaml = r#"# Minimal config for xhs_e2e diagnostic.
# `dns:` is stripped + replaced by the FFI's pinned block, so omit it.
# Listener ports are stripped too. Rules send everything DIRECT — we want
# to verify the in-TUN data path, not a particular outbound's correctness.
mode: rule
log-level: info
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
"#;
    let p = dir.join("config.yaml");
    std::fs::write(&p, yaml).expect("write config");
    p
}

fn seed_home(repo_root: &Path) -> PathBuf {
    let tmp = std::env::temp_dir().join(format!("meow-xhs-e2e-{}", std::process::id()));
    let mihomo = tmp.join("mihomo");
    std::fs::create_dir_all(&mihomo).expect("mkdir home/mihomo");
    let geox = repo_root.join("App/Resources/geox");
    for asset in ["Country.mmdb", "cn-ipv4.bin", "cn-ipv6.bin"] {
        let src = geox.join(asset);
        let dst = mihomo.join(asset);
        if src.exists() {
            std::fs::copy(&src, &dst)
                .unwrap_or_else(|e| panic!("copy {} -> {}: {e}", src.display(), dst.display()));
        } else {
            panic!("missing fixture: {}", src.display());
        }
    }
    tmp
}

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is .../core/rust/mihomo-ios-ffi
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf()
}

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------

#[test]
fn xhs_dns_and_tcp_roundtrip() {
    // Mirror PacketTunnelProvider startup.
    let home = seed_home(&repo_root());
    let cfg = write_min_config(&home);

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    *EGRESS_TX.lock().unwrap() = Some(tx);

    meow_core_init();
    let home_c = CString::new(home.to_string_lossy().as_bytes()).unwrap();
    unsafe { meow_core_set_home_dir(home_c.as_ptr()) };

    let cfg_c = CString::new(cfg.to_string_lossy().as_bytes()).unwrap();
    let rc = unsafe { meow_engine_start(cfg_c.as_ptr()) };
    assert_eq!(rc, 0, "engine_start failed: {}", last_ffi_error());

    let rc = unsafe { meow_tun_start(std::ptr::null_mut(), egress_trampoline) };
    assert_eq!(rc, 0, "tun_start failed: {}", last_ffi_error());

    // Give the engine a moment to publish the resolver — `engine::start`
    // is synchronous about this, but the mihomo resolver itself does
    // first-call upstream resolution lazily, so warm it up before timing
    // anything.
    std::thread::sleep(Duration::from_millis(50));

    // -----------------------------------------------------------------
    // Probe the engine resolver directly via the FFI, side-stepping
    // fake_ip_dns entirely. This isolates whether the resolver itself
    // can reach the pinned upstream DNS (119.29.29.29 / 223.5.5.5 /
    // 1.1.1.1) from the test host.
    //
    // We probe three names:
    //   * baidu.com           — canonical CN, must land in cn-ipv4 table.
    //   * github.com          — canonical non-CN, must NOT land in table.
    //   * www.xiaohongshu.com — the actual subject.
    //
    // If baidu.com fails to resolve, the issue is the resolver / host
    // network — not xiaohongshu-specific. If baidu.com resolves to a CN
    // IP but xiaohongshu.com resolves to a non-CN CDN, the issue is
    // the cn-ipv4 table coverage, not the FFI logic.
    // -----------------------------------------------------------------
    for host in ["baidu.com", "github.com", "www.xiaohongshu.com"] {
        ffi_dns_probe(host, 2000);
    }

    // Direct-TCP probe uses `tokio::net::TcpStream::connect` after the
    // OS-level `to_socket_addrs`. It side-steps the mihomo resolver
    // entirely, so a success here with low latency proves the destination
    // host is reachable on the real network — which makes a same-host
    // failure inside the in-TUN flow attributable to the in-engine path,
    // not the network.
    for host in ["baidu.com", "www.xiaohongshu.com"] {
        ffi_tcp_probe(host, 443, 3000);
    }

    // cn-ipv4 table sanity. We resolve via the host's OS so the table
    // check is independent of the FFI/mihomo resolver. If a known CN
    // sample lands inside the table, the table is loaded correctly;
    // the membership question is then specifically about whatever IP
    // xiaohongshu.com resolves to on this network.
    cn_table_probe(["baidu.com", "www.xiaohongshu.com"]);
    eprintln!();

    // -----------------------------------------------------------------
    // Layer 1: DNS A query for xiaohongshu.com via the in-TUN UDP/53
    // intercept. Build an IPv4 + UDP packet src=172.19.0.1:53535,
    // dst=172.19.0.2:53 (matching iOS NEPacketTunnelNetworkSettings
    // addressing), feed it to `meow_tun_ingest`, and wait for a reply
    // packet on the egress channel.
    // -----------------------------------------------------------------
    let qname = "www.xiaohongshu.com";
    let dns_id = 0x4A4Au16;
    let query = dns_a_query(qname, dns_id);
    let pkt = build_ipv4_udp([172, 19, 0, 1], [172, 19, 0, 2], 53535, 53, &query);
    eprintln!(
        "xhs_e2e: ingesting DNS A query for {qname} (pkt len = {})",
        pkt.len()
    );
    let rc = unsafe { meow_tun_ingest(pkt.as_ptr(), pkt.len()) };
    assert_eq!(rc, 0, "tun_ingest returned {rc}");

    let dns_reply = wait_for_dns_reply(&rx, dns_id, Duration::from_secs(5));
    let resolved_ip = match dns_reply {
        Some(ip) => ip,
        None => {
            cleanup();
            panic!(
                "xhs_e2e: no DNS A response for {qname} within 5s — \
                 see stderr; resolver upstream may be unreachable, or \
                 the fake_ip_dns intercept stalled"
            );
        }
    };
    let is_fake = resolved_ip[0] == 28;
    eprintln!(
        "xhs_e2e: DNS resolved {qname} -> {}.{}.{}.{} ({})",
        resolved_ip[0],
        resolved_ip[1],
        resolved_ip[2],
        resolved_ip[3],
        if is_fake {
            "FAKE-IP — CN-bypass DID NOT fire (resolver upstream failed, or cn-ipv4 table missing/mis-matched)"
        } else {
            "REAL IP — CN-bypass fired (direct-route candidate)"
        }
    );

    // -----------------------------------------------------------------
    // Layer 2: TCP SYN to the resolved IP:443 via the same TUN path.
    // We don't complete the three-way handshake — that would require a
    // mini smoltcp client on the test side. What we DO want to see is
    // *whether* the netstack accepts the flow at all (the egress should
    // contain a SYN-ACK from netstack-smoltcp within a few hundred ms;
    // absence of one means the netstack is refusing the SYN, which is
    // itself the bug.)
    // -----------------------------------------------------------------
    let syn = build_ipv4_tcp_syn([172, 19, 0, 1], resolved_ip, 45123, 443, 0xDEAD_BEEF);
    eprintln!("xhs_e2e: ingesting TCP SYN to {}:443", fmt_ip(resolved_ip));
    let rc = unsafe { meow_tun_ingest(syn.as_ptr(), syn.len()) };
    assert_eq!(rc, 0, "tun_ingest(SYN) returned {rc}");

    let synack = wait_for_tcp_synack(&rx, resolved_ip, 45123, Duration::from_secs(3));
    let synack = match synack {
        Some(info) => {
            eprintln!(
                "xhs_e2e: netstack returned SYN-ACK seq={:#x} ack={:#x}",
                info.seq, info.ack
            );
            info
        }
        None => {
            eprintln!(
                "xhs_e2e: NO SYN-ACK within 3s for {}:443 — netstack declined the SYN.",
                fmt_ip(resolved_ip)
            );
            cleanup();
            return;
        }
    };

    // -----------------------------------------------------------------
    // Layer 3: complete the 3WHS and send a real TLS ClientHello with
    // SNI=www.xiaohongshu.com. The netstack relays the bytes into
    // dispatch_tcp_via_mihomo, which builds Metadata{host=...}, asks
    // mihomo's rule engine for an outbound (DIRECT for our minimal
    // config), and DirectAdapter::resolve_target resolves via
    // `resolver.resolve_ip()` — which (unlike `lookup_ipv4` used by
    // cn_bypass_v4) bypasses fake-IP mode in mihomo-rust v0.7.2 and
    // returns the actual upstream IP. mihomo dials, plumbs the TCP
    // relay, and any TLS ServerHello it reads from upstream comes back
    // as in-TUN segments on the egress callback.
    //
    // What we look for: any IPv4+TCP segment from `resolved_ip:443` to
    // our `src_port` carrying a non-empty payload. The first byte of
    // a TLS record is the content type (0x16 = handshake), so if we
    // see `[0x16, 0x03, ...]` the upstream answered our ClientHello.
    // -----------------------------------------------------------------
    let client_seq = 0xDEAD_BEEF_u32.wrapping_add(1);
    let server_seq = synack.seq.wrapping_add(1);
    let client_hello = build_tls_client_hello(qname);
    let ack_data_pkt = build_ipv4_tcp_data(
        [172, 19, 0, 1],
        resolved_ip,
        45123,
        443,
        client_seq,
        server_seq,
        &client_hello,
    );
    eprintln!(
        "xhs_e2e: ingesting TLS ClientHello SNI={qname} ({} bytes)",
        client_hello.len()
    );
    let rc = unsafe { meow_tun_ingest(ack_data_pkt.as_ptr(), ack_data_pkt.len()) };
    assert_eq!(rc, 0, "tun_ingest(ACK+data) returned {rc}");

    let server_reply = wait_for_tcp_data(&rx, resolved_ip, 45123, Duration::from_secs(10));
    match server_reply {
        Some(payload) => {
            let head: Vec<String> = payload
                .iter()
                .take(8)
                .map(|b| format!("{:02x}", b))
                .collect();
            let is_tls_handshake = payload.len() >= 3 && payload[0] == 0x16 && payload[1] == 0x03;
            eprintln!(
                "xhs_e2e: upstream replied with {} bytes; head=[{}] — {}",
                payload.len(),
                head.join(" "),
                if is_tls_handshake {
                    "looks like a TLS ServerHello (handshake/0x16). End-to-end \
                     in-TUN path is functional for xiaohongshu.com via DIRECT."
                } else {
                    "payload is NOT a TLS record — connection terminated or the \
                     engine returned an unexpected byte stream."
                }
            );
        }
        None => {
            eprintln!(
                "xhs_e2e: NO upstream data within 10s — the engine either \
                 failed to dial the real host, the rule chain dropped the \
                 flow (REJECT), or the upstream silently held the \
                 connection. This is the symptom that maps directly to \
                 'page hangs' on-device. Check engine log for `direct: \
                 failed to resolve {qname}` or rule-matcher output."
            );
        }
    }

    cleanup();
}

/// Build an IPv4 + TCP segment with PSH+ACK flags carrying `payload`.
fn build_ipv4_tcp_data(
    src: [u8; 4],
    dst: [u8; 4],
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    payload: &[u8],
) -> Vec<u8> {
    let total_len: u16 = 40 + payload.len() as u16;
    let mut pkt = Vec::with_capacity(total_len as usize);
    pkt.push(0x45);
    pkt.push(0x00);
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&[0x00, 0x02]);
    pkt.extend_from_slice(&[0x40, 0x00]);
    pkt.push(64);
    pkt.push(6);
    pkt.extend_from_slice(&[0, 0]);
    pkt.extend_from_slice(&src);
    pkt.extend_from_slice(&dst);
    let ck = ipv4_header_checksum(&pkt[..20]);
    pkt[10..12].copy_from_slice(&ck.to_be_bytes());
    pkt.extend_from_slice(&src_port.to_be_bytes());
    pkt.extend_from_slice(&dst_port.to_be_bytes());
    pkt.extend_from_slice(&seq.to_be_bytes());
    pkt.extend_from_slice(&ack.to_be_bytes());
    pkt.push(0x50);
    pkt.push(0x18); // PSH+ACK
    pkt.extend_from_slice(&65535u16.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]);
    pkt.extend_from_slice(&[0, 0]);
    pkt.extend_from_slice(payload);
    let tcp_len = (pkt.len() - 20) as u16;
    let mut sum = pseudo_header_sum(src, dst, 6, tcp_len);
    for chunk in pkt[20..].chunks(2) {
        if chunk.len() == 2 {
            sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
        } else {
            sum += u32::from(u16::from_be_bytes([chunk[0], 0]));
        }
    }
    let ck = fold_checksum(sum);
    pkt[36..38].copy_from_slice(&ck.to_be_bytes());
    pkt
}

/// Wait for a TCP segment carrying a non-empty data payload from
/// `expected_src_ip:443` to our `expected_dst_port`. Returns the payload.
fn wait_for_tcp_data(
    rx: &mpsc::Receiver<Vec<u8>>,
    expected_src_ip: [u8; 4],
    expected_dst_port: u16,
    timeout: Duration,
) -> Option<Vec<u8>> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let pkt = match rx.recv_timeout(remaining) {
            Ok(p) => p,
            Err(_) => return None,
        };
        if pkt.len() < 40 || pkt[0] >> 4 != 4 || pkt[9] != 6 {
            continue;
        }
        let src_ip = [pkt[12], pkt[13], pkt[14], pkt[15]];
        if src_ip != expected_src_ip {
            continue;
        }
        let ihl = ((pkt[0] & 0x0F) as usize) * 4;
        if pkt.len() < ihl + 20 {
            continue;
        }
        let dst_port = u16::from_be_bytes([pkt[ihl + 2], pkt[ihl + 3]]);
        if dst_port != expected_dst_port {
            continue;
        }
        let data_offset = ((pkt[ihl + 12] >> 4) as usize) * 4;
        let payload_start = ihl + data_offset;
        if payload_start >= pkt.len() {
            continue;
        }
        let payload = pkt[payload_start..].to_vec();
        if payload.is_empty() {
            continue;
        }
        return Some(payload);
    }
    None
}

/// Build a minimal TLS 1.2 ClientHello with a single SNI extension. Not a
/// fully spec'd handshake — just enough to elicit a ServerHello (or a
/// fatal alert) from a real TLS server. Cipher suite list is the modern
/// "any" set; extensions cover supported_versions, signature_algorithms,
/// supported_groups, key_share, and SNI.
fn build_tls_client_hello(sni: &str) -> Vec<u8> {
    let sni_bytes = sni.as_bytes();
    // SNI extension body: list length(2) + type(1) + name length(2) + name
    let mut sni_ext = Vec::new();
    sni_ext.extend_from_slice(&((sni_bytes.len() + 3) as u16).to_be_bytes());
    sni_ext.push(0); // host_name
    sni_ext.extend_from_slice(&(sni_bytes.len() as u16).to_be_bytes());
    sni_ext.extend_from_slice(sni_bytes);

    // Build extensions block.
    let mut exts = Vec::new();
    // SNI (type 0x0000)
    exts.extend_from_slice(&0u16.to_be_bytes());
    exts.extend_from_slice(&(sni_ext.len() as u16).to_be_bytes());
    exts.extend_from_slice(&sni_ext);
    // supported_versions (0x002b): list of one — TLS 1.2 (0x0303)
    exts.extend_from_slice(&0x002bu16.to_be_bytes());
    exts.extend_from_slice(&3u16.to_be_bytes());
    exts.push(2);
    exts.extend_from_slice(&0x0303u16.to_be_bytes());
    // supported_groups (0x000a): X25519 (0x001d)
    exts.extend_from_slice(&0x000au16.to_be_bytes());
    exts.extend_from_slice(&4u16.to_be_bytes());
    exts.extend_from_slice(&2u16.to_be_bytes());
    exts.extend_from_slice(&0x001du16.to_be_bytes());
    // signature_algorithms (0x000d): rsa_pss_rsae_sha256 (0x0804)
    exts.extend_from_slice(&0x000du16.to_be_bytes());
    exts.extend_from_slice(&4u16.to_be_bytes());
    exts.extend_from_slice(&2u16.to_be_bytes());
    exts.extend_from_slice(&0x0804u16.to_be_bytes());

    // ClientHello body.
    let mut body = Vec::new();
    body.extend_from_slice(&0x0303u16.to_be_bytes()); // legacy_version TLS 1.2
    body.extend(std::iter::repeat_n(0xAB_u8, 32)); // random
    body.push(0); // session_id length
                  // cipher_suites: TLS_AES_128_GCM_SHA256 (0x1301), TLS_RSA_WITH_AES_128_GCM_SHA256 (0x009c)
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&0x1301u16.to_be_bytes());
    body.extend_from_slice(&0x009cu16.to_be_bytes());
    // compression: null
    body.push(1);
    body.push(0);
    // extensions
    body.extend_from_slice(&(exts.len() as u16).to_be_bytes());
    body.extend_from_slice(&exts);

    // Handshake header.
    let mut hs = Vec::new();
    hs.push(0x01); // ClientHello
    let len = body.len() as u32;
    hs.push((len >> 16) as u8);
    hs.push((len >> 8) as u8);
    hs.push(len as u8);
    hs.extend_from_slice(&body);

    // TLS record header.
    let mut rec = Vec::new();
    rec.push(0x16); // handshake
    rec.extend_from_slice(&0x0301u16.to_be_bytes()); // record version
    rec.extend_from_slice(&(hs.len() as u16).to_be_bytes());
    rec.extend_from_slice(&hs);
    rec
}

/// Call `meow_engine_test_dns(host)` and print the resolved IPs. This
/// hits the engine resolver directly (bypassing fake-IP DNS and the
/// CN-bypass probe), so we can tell whether the resolver itself
/// is reaching its upstreams.
fn ffi_dns_probe(host: &str, timeout_ms: i32) {
    let host_c = CString::new(host).unwrap();
    let mut buf = vec![0u8; 1024];
    let rc = unsafe {
        meow_engine_test_dns(
            host_c.as_ptr(),
            timeout_ms,
            buf.as_mut_ptr() as *mut i8,
            buf.len() as i32,
        )
    };
    if rc < 0 {
        eprintln!("xhs_e2e: resolver({host}) -> ERR ({})", last_ffi_error());
        return;
    }
    let n = rc as usize;
    let s = std::str::from_utf8(&buf[..n.min(buf.len())])
        .unwrap_or("<non-utf8>")
        .to_string();
    eprintln!("xhs_e2e: resolver({host}) -> [{s}]");
}

fn ffi_tcp_probe(host: &str, port: i32, timeout_ms: i32) {
    let host_c = CString::new(host).unwrap();
    let mut ms: i64 = 0;
    let rc = unsafe {
        meow_engine_test_direct_tcp(host_c.as_ptr(), port, timeout_ms, &mut ms as *mut i64)
    };
    if rc < 0 {
        eprintln!(
            "xhs_e2e: direct_tcp({host}:{port}) -> ERR ({})",
            last_ffi_error()
        );
    } else {
        eprintln!("xhs_e2e: direct_tcp({host}:{port}) -> {ms}ms");
    }
}

/// Parse `<home>/mihomo/cn-ipv4.bin` and check membership for each host
/// — but resolve via direct UDP/53 queries to specific upstream
/// nameservers rather than going through the OS resolver. The OS
/// resolver can be configured to use a non-CN upstream (corp DNS,
/// 8.8.8.8, …), which returns a non-CN PoP for hosts that have global
/// CDN coverage like xiaohongshu.com. Querying the same nameservers
/// the FFI pins for the engine makes the test see what the engine sees.
///
/// We probe both 119.29.29.29 (DNSPod, CN-side) and 1.1.1.1
/// (Cloudflare, global) and print both answers so the disparity is
/// visible. For one or both nameservers being unreachable from the
/// test host, the membership line shows `<unreachable>`.
fn cn_table_probe<const N: usize>(hosts: [&str; N]) {
    let path = std::env::temp_dir()
        .join(format!("meow-xhs-e2e-{}", std::process::id()))
        .join("mihomo")
        .join("cn-ipv4.bin");
    let intervals = match load_cn_v4(&path) {
        Ok(iv) => iv,
        Err(e) => {
            eprintln!(
                "xhs_e2e: cn-ipv4 table load FAILED ({}): {e}",
                path.display()
            );
            return;
        }
    };
    eprintln!(
        "xhs_e2e: cn-ipv4 table: {} intervals from {}",
        intervals.len(),
        path.display()
    );

    // Same nameserver set the FFI pins (`pinned_dns_block` in engine.rs).
    // Querying each in turn so we see the per-nameserver answer.
    let resolvers: [(&str, std::net::Ipv4Addr); 3] = [
        ("DNSPod CN", std::net::Ipv4Addr::new(119, 29, 29, 29)),
        ("Alibaba CN", std::net::Ipv4Addr::new(223, 5, 5, 5)),
        ("Cloudflare global", std::net::Ipv4Addr::new(1, 1, 1, 1)),
    ];

    // OS-resolver baseline first — shows what `getaddrinfo` (which is
    // sensitive to /etc/resolv.conf, scutil DNS, VPN-injected resolvers,
    // etc.) returns on this host. Useful as a control: if the OS-resolver
    // answer differs from the per-nameserver answers, the test host's
    // resolver path is itself proxied / non-CN.
    for host in hosts {
        let os_resolved: Option<std::net::Ipv4Addr> =
            (host, 0u16).to_socket_addrs().ok().and_then(|mut it| {
                it.find_map(|s| match s.ip() {
                    std::net::IpAddr::V4(v) => Some(v),
                    _ => None,
                })
            });
        match os_resolved {
            None => eprintln!("xhs_e2e:   OS-resolver({host}) -> <no v4>"),
            Some(ip) => eprintln!(
                "xhs_e2e:   OS-resolver({host}) -> {ip}  cn-table={}",
                in_cn_table(&intervals, ip)
            ),
        }
        for (label, ns) in &resolvers {
            match direct_udp_dns_query(host, *ns, Duration::from_millis(1500)) {
                Ok(ips) => {
                    if ips.is_empty() {
                        eprintln!("xhs_e2e:   {label} @ {ns} ({host}) -> <empty answer>");
                    } else {
                        for ip in &ips {
                            eprintln!(
                                "xhs_e2e:   {label} @ {ns} ({host}) -> {ip}  cn-table={}",
                                in_cn_table(&intervals, *ip)
                            );
                        }
                    }
                }
                Err(e) => eprintln!("xhs_e2e:   {label} @ {ns} ({host}) -> <unreachable>: {e}"),
            }
        }
    }
}

/// True iff `ip` is covered by any interval in the pre-loaded cn-ipv4
/// table. Mirrors `cn_iprange::contains_v4`.
fn in_cn_table(intervals: &[(u32, u32)], ip: std::net::Ipv4Addr) -> bool {
    let key = u32::from(ip);
    let idx = intervals.partition_point(|(s, _)| *s <= key);
    if idx == 0 {
        return false;
    }
    key <= intervals[idx - 1].1
}

/// Bind an ephemeral UDP socket, send a single A query for `host` to
/// `nameserver:53`, wait up to `timeout` for the reply, parse the A
/// answers. No retries, no TCP fallback, no EDNS0 — minimal stub
/// resolver, sufficient for diagnostic.
fn direct_udp_dns_query(
    host: &str,
    nameserver: std::net::Ipv4Addr,
    timeout: Duration,
) -> std::io::Result<Vec<std::net::Ipv4Addr>> {
    let sock = UdpSocket::bind("0.0.0.0:0")?;
    sock.set_read_timeout(Some(timeout))?;
    let addr = SocketAddr::from((nameserver, 53));
    // Random-ish id; collisions don't matter at this scale.
    let id = (Instant::now().elapsed().as_nanos() as u16) | 0x8000;
    let query = dns_a_query(host, id);
    sock.send_to(&query, addr)?;
    let mut buf = [0u8; 1500];
    let (n, from) = sock.recv_from(&mut buf)?;
    if from.ip() != std::net::IpAddr::V4(nameserver) {
        return Err(std::io::Error::other(format!(
            "reply from unexpected source {from}"
        )));
    }
    let (rcode, ips) = parse_dns_a_response(&buf[..n]);
    if rcode != 0 && ips.is_empty() {
        return Err(std::io::Error::other(format!(
            "server returned rcode={rcode}"
        )));
    }
    Ok(ips
        .into_iter()
        .map(|b| std::net::Ipv4Addr::new(b[0], b[1], b[2], b[3]))
        .collect())
}

fn load_cn_v4(path: &std::path::Path) -> std::io::Result<Vec<(u32, u32)>> {
    let bytes = std::fs::read(path)?;
    if bytes.len() < 12 || &bytes[0..4] != b"CNIP" {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "bad magic",
        ));
    }
    let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
    let body = &bytes[12..];
    if body.len() != count * 8 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "body size mismatch",
        ));
    }
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let off = i * 8;
        let start = u32::from_le_bytes(body[off..off + 4].try_into().unwrap());
        let end = u32::from_le_bytes(body[off + 4..off + 8].try_into().unwrap());
        out.push((start, end));
    }
    Ok(out)
}

fn cleanup() {
    meow_tun_stop();
    meow_engine_stop();
    *EGRESS_TX.lock().unwrap() = None;
}

fn fmt_ip(ip: [u8; 4]) -> String {
    format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
}

/// Drain the egress channel waiting for a DNS reply that matches `dns_id`.
fn wait_for_dns_reply(
    rx: &mpsc::Receiver<Vec<u8>>,
    dns_id: u16,
    timeout: Duration,
) -> Option<[u8; 4]> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let pkt = match rx.recv_timeout(remaining) {
            Ok(p) => p,
            Err(_) => return None,
        };
        // IPv4 + UDP only.
        if pkt.len() < 28 || pkt[0] >> 4 != 4 || pkt[9] != 17 {
            continue;
        }
        let ihl = ((pkt[0] & 0x0F) as usize) * 4;
        if pkt.len() < ihl + 8 {
            continue;
        }
        let src_port = u16::from_be_bytes([pkt[ihl], pkt[ihl + 1]]);
        if src_port != 53 {
            continue;
        }
        let dns_payload = &pkt[ihl + 8..];
        if dns_payload.len() < 12 {
            continue;
        }
        let id = u16::from_be_bytes([dns_payload[0], dns_payload[1]]);
        if id != dns_id {
            continue;
        }
        let (rcode, ips) = parse_dns_a_response(dns_payload);
        eprintln!("xhs_e2e: DNS reply rcode={rcode} answers={}", ips.len());
        if rcode != 0 || ips.is_empty() {
            return None;
        }
        return Some(ips[0]);
    }
    None
}

struct TcpInfo {
    seq: u32,
    ack: u32,
}

fn wait_for_tcp_synack(
    rx: &mpsc::Receiver<Vec<u8>>,
    expected_src_ip: [u8; 4],
    expected_dst_port: u16,
    timeout: Duration,
) -> Option<TcpInfo> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let pkt = match rx.recv_timeout(remaining) {
            Ok(p) => p,
            Err(_) => return None,
        };
        if pkt.len() < 40 || pkt[0] >> 4 != 4 || pkt[9] != 6 {
            continue;
        }
        let src_ip = [pkt[12], pkt[13], pkt[14], pkt[15]];
        if src_ip != expected_src_ip {
            continue;
        }
        let ihl = ((pkt[0] & 0x0F) as usize) * 4;
        if pkt.len() < ihl + 20 {
            continue;
        }
        let dst_port = u16::from_be_bytes([pkt[ihl + 2], pkt[ihl + 3]]);
        if dst_port != expected_dst_port {
            continue;
        }
        let flags = pkt[ihl + 13];
        if flags & 0x12 != 0x12 {
            // need SYN+ACK
            continue;
        }
        let seq = u32::from_be_bytes([pkt[ihl + 4], pkt[ihl + 5], pkt[ihl + 6], pkt[ihl + 7]]);
        let ack = u32::from_be_bytes([pkt[ihl + 8], pkt[ihl + 9], pkt[ihl + 10], pkt[ihl + 11]]);
        return Some(TcpInfo { seq, ack });
    }
    None
}
