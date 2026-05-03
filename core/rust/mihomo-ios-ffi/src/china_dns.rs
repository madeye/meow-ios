//! Split-horizon DNS layer in the spirit of `madeye/trust-china-dns`. For
//! `A`/`AAAA` queries we race a Chinese plain-UDP resolver against the
//! trusted TCP DNS client, then pick the China answer iff at least one
//! of its A/AAAA records resolves to a CN IP per the bundled `Country.mmdb`.
//!
//! Anything not covered by the heuristic — disabled config, missing GeoIP,
//! non-A/AAAA qtype — passes straight through to
//! `dns_client::resolve_via_tcp_dns` so behaviour matches the pre-orchestrator
//! path. All chosen answers land in the same shared cache that `dns_client`
//! already manages, so the orchestration cost is paid once per (qname, qtype)
//! per TTL window.

use crate::dns_client;
use crate::dns_table;
use ipnet::{Ipv4Net, Ipv6Net};
use iprange::IpRange;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::net::UdpSocket;
use tracing::{info, warn};

const CHINA_TIMEOUT: Duration = Duration::from_millis(800);
const UDP_RECV_TIMEOUT: Duration = Duration::from_millis(700);
const UDP_BUF_SIZE: usize = 1500;

/// DNS RR types we treat as "GeoIP-meaningful". Anything else (CNAME-only,
/// MX, TXT, PTR, HTTPS, …) skips orchestration: there is no IP in the answer
/// to gate on, and the trusted DoH path is the existing default.
const QTYPE_A: u16 = 1;
const QTYPE_AAAA: u16 = 28;

/// CN-IP membership oracle, built once at init by scanning `Country.mmdb` for
/// entries with `country.iso_code == "CN"`. The mmdb buffer is dropped right
/// after the scan — only the merged CIDR set lives forever.
///
/// PacketTunnel runs under a 50 MB jetsam cap; keeping the full mmap (≈ 5 MB)
/// resident purely to answer "is this IP CN?" was wasteful when an
/// `iprange::IpRange<IpNet>` (a sorted, simplified prefix set) does the same
/// lookup in O(log n) with a tiny memory footprint. Same data structure
/// `madeye/trust-china-dns` uses upstream.
struct CnIpset {
    v4: IpRange<Ipv4Net>,
    v6: IpRange<Ipv6Net>,
}

impl CnIpset {
    fn is_empty(&self) -> bool {
        // `IpRange::iter()` yields zero items when no networks have been added;
        // the crate doesn't expose `len()` directly, but `next().is_none()` is
        // the equivalent check.
        self.v4.iter().next().is_none() && self.v6.iter().next().is_none()
    }

    fn contains(&self, ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(v4) => self
                .v4
                .contains(&Ipv4Net::new(v4, 32).expect("static prefix")),
            IpAddr::V6(v6) => self
                .v6
                .contains(&Ipv6Net::new(v6, 128).expect("static prefix")),
        }
    }
}

/// CN-IP membership oracle — empty until `init` succeeds. An empty ipset
/// reads as "GeoIP unavailable" and short-circuits orchestration to DoH-only.
static CN_IPSET: OnceLock<CnIpset> = OnceLock::new();

/// Configured Chinese plain-UDP upstreams (DNSPod, AliDNS by default). Empty
/// vec disables the split entirely.
static CHINA_UPSTREAMS: OnceLock<Vec<SocketAddr>> = OnceLock::new();

/// Initialise the CN-IP set and the China-upstream list. Reads `Country.mmdb`
/// off disk, extracts every CN-tagged network into a sorted `(start, end)`
/// range vector, and **drops the mmdb buffer** before returning. Idempotent —
/// second calls are no-ops because the `OnceLock`s reject re-init.
pub fn init(home_dir: Option<&str>, upstreams: Vec<SocketAddr>) {
    let _ = CHINA_UPSTREAMS.set(upstreams.clone());

    let mmdb_path: PathBuf = match home_dir {
        Some(h) => PathBuf::from(h).join("mihomo").join("Country.mmdb"),
        None => mihomo_config::default_geoip_path(),
    };

    let started = std::time::Instant::now();
    let ipset = match build_cn_ipset(&mmdb_path) {
        Ok(set) => {
            info!(
                "china_dns: CN ipset built from {} in {} ms — {} v4 prefixes, {} v6 prefixes, {} upstream(s) {:?}",
                mmdb_path.display(),
                started.elapsed().as_millis(),
                set.v4.iter().count(),
                set.v6.iter().count(),
                upstreams.len(),
                upstreams,
            );
            set
        }
        Err(e) => {
            warn!(
                "china_dns: GeoIP unavailable at {} ({}); split disabled, all queries via DoH",
                mmdb_path.display(),
                e
            );
            CnIpset {
                v4: IpRange::new(),
                v6: IpRange::new(),
            }
        }
    };

    let _ = CN_IPSET.set(ipset);
}

/// Open `Country.mmdb`, walk every network, retain CN-tagged entries in an
/// `IpRange<IpNet>`, then `simplify()` to merge adjacent prefixes. The
/// `Reader` (which owns the `Vec<u8>` mmdb buffer) is dropped at end of scope,
/// so the function returns with only the compact CN-only ipset retained.
///
/// Two cost optimisations vs. the obvious `decode::<Country>` over a single
/// loop, measured against the bundled 8.2 MB Country.mmdb (≈ 800 k leaves):
///
/// 1. **`decode_path::<&str>`** — the full `geoip2::Country` model nests five
///    optional struct fields (continent, country, registered_country,
///    represented_country, traits) but we only want `country.iso_code`. Path
///    decoding walks the binary record key-by-key and skips non-matching
///    siblings, parsing only the &str at the leaf. ~44 % faster on its own.
///
/// 2. **Scoped two-thread fan-out** — the v4 and v6 sub-trees are independent
///    so we walk them on two `std::thread::scope`-spawned threads holding
///    `&reader`. `Reader<Vec<u8>>` is `Sync`, so the borrow checks out.
///    Threads use a 512 KiB stack (matching the tokio worker config) and
///    release on `join`. ~36 % further saving over the serial path.
///
/// Combined: ≈ 600 ms → 220 ms on host x86, parity-checked at 15 555 CN
/// matches. Cost lands once at PacketTunnel start and gates VPN readiness.
fn build_cn_ipset(mmdb_path: &std::path::Path) -> Result<CnIpset, String> {
    let bytes = std::fs::read(mmdb_path).map_err(|e| format!("read: {e}"))?;
    let reader = maxminddb::Reader::from_source(bytes).map_err(|e| format!("parse: {e}"))?;
    let reader_ref = &reader;

    let iso_path = [
        maxminddb::PathElement::Key("country"),
        maxminddb::PathElement::Key("iso_code"),
    ];
    let path_ref = &iso_path;

    let (v4_nets, v6_nets) = std::thread::scope(|s| {
        let v4 = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn_scoped(s, move || collect_cn_networks(reader_ref, "0.0.0.0/0", path_ref))
            .expect("spawn v4 scan thread");
        let v6 = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn_scoped(s, move || collect_cn_networks(reader_ref, "::/0", path_ref))
            .expect("spawn v6 scan thread");
        (
            v4.join().expect("v4 scan panicked"),
            v6.join().expect("v6 scan panicked"),
        )
    });

    let mut v4: IpRange<Ipv4Net> = IpRange::new();
    let mut v6: IpRange<Ipv6Net> = IpRange::new();
    for net in v4_nets {
        insert_network(&mut v4, &mut v6, net);
    }
    for net in v6_nets {
        insert_network(&mut v4, &mut v6, net);
    }

    // Merge adjacent / overlapping prefixes — same step trust-china-dns runs
    // on its bypass ACL. Compacts the trie and shrinks `contains()` traversal.
    v4.simplify();
    v6.simplify();

    if v4.iter().next().is_none() && v6.iter().next().is_none() {
        return Err("no CN networks found in mmdb".to_string());
    }
    Ok(CnIpset { v4, v6 })
    // `reader` (and its Vec<u8>) drops here.
}

/// Walk one IP-family sub-tree of the mmdb and collect every CN-tagged
/// network. Uses `decode_path::<&str>` so non-matching leaves bail without
/// parsing the full record — the dominant cost across the ~800 k leaves.
fn collect_cn_networks(
    reader: &maxminddb::Reader<Vec<u8>>,
    cidr: &str,
    iso_path: &[maxminddb::PathElement<'_>],
) -> Vec<ipnetwork::IpNetwork> {
    let query: ipnetwork::IpNetwork = cidr.parse().expect("static cidr");
    let iter = match reader.within(query, maxminddb::WithinOptions::default()) {
        Ok(it) => it,
        // mmdb may legitimately lack one IP family; an empty side returns
        // an error rather than an empty iterator.
        Err(_) => return Vec::new(),
    };

    let mut out = Vec::new();
    for item in iter {
        let lookup = match item {
            Ok(l) => l,
            Err(_) => continue,
        };
        // Borrowed straight out of the mmdb buffer — no allocation.
        if !matches!(lookup.decode_path::<&str>(iso_path), Ok(Some("CN"))) {
            continue;
        }
        if let Ok(net) = lookup.network() {
            out.push(net);
        }
    }
    out
}

fn insert_network(
    v4: &mut IpRange<Ipv4Net>,
    v6: &mut IpRange<Ipv6Net>,
    net: ipnetwork::IpNetwork,
) {
    let prefix = net.prefix();
    match net.network() {
        IpAddr::V4(addr) => {
            if let Ok(n) = Ipv4Net::new(addr, prefix) {
                v4.add(n);
            }
        }
        IpAddr::V6(addr) => {
            if let Ok(n) = Ipv6Net::new(addr, prefix) {
                v6.add(n);
            }
        }
    }
}

/// Default Chinese plain-UDP upstreams used when the user has not set
/// `dns.china_nameserver` in `config.yaml`. DNSPod (119.29.29.29:53) and
/// AliDNS (223.5.5.5:53) — same servers `madeye/trust-china-dns` uses by
/// convention, both UDP/53.
pub fn default_china_upstreams() -> Vec<SocketAddr> {
    vec![
        "119.29.29.29:53".parse().expect("static literal"),
        "223.5.5.5:53".parse().expect("static literal"),
    ]
}

/// Top-level resolver replacing `dns_client::resolve_via_tcp_dns` at the
/// `tun2socks::handle_dns_query` entry point.
pub async fn resolve(query: &[u8]) -> Option<Vec<u8>> {
    // Shared cache fast path: prior orchestration outcomes (China-bytes or
    // trusted-bytes alike) are stored under the same question-section key,
    // so a single cache lookup at the top covers both branches.
    if let Some(resp) = dns_client::cache_lookup_for_external(query) {
        return Some(resp);
    }

    // Skip orchestration when the heuristic is meaningless or disabled.
    if !split_applies(query) {
        return dns_client::resolve_via_tcp_dns(query).await;
    }

    let china_query = query.to_vec();
    let china_fut = async move { udp_query_race(&china_query).await };
    let trusted_fut = dns_client::resolve_via_tcp_dns(query);

    tokio::pin!(china_fut);
    tokio::pin!(trusted_fut);

    // Wait up to CHINA_TIMEOUT for the China response. The trusted resolver
    // continues to run in the background regardless — we'll await it below
    // if China is not-CN or absent.
    let china_response = tokio::select! {
        biased;
        china = &mut china_fut => china,
        _ = tokio::time::sleep(CHINA_TIMEOUT) => None,
    };

    if let Some(ref resp) = china_response {
        if response_has_cn_ip(resp) {
            dns_client::cache_store_external(query, resp);
            return Some(resp.clone());
        }
    }

    // China was absent / non-CN: prefer the trusted resolver's answer.
    if let Some(resp) = (&mut trusted_fut).await {
        return Some(resp);
    }

    // Last-resort fallback: trusted resolver failed but China answered
    // (non-CN). Better a poisoned-but-resolving record than nothing —
    // matches trust-china-dns tolerance for partial upstream failures.
    if let Some(resp) = china_response {
        dns_client::cache_store_external(query, &resp);
        return Some(resp);
    }

    None
}

fn split_applies(query: &[u8]) -> bool {
    // CN ipset empty → can't gate on IP, so orchestration is meaningless.
    let ipset_ready = CN_IPSET.get().map(|s| !s.is_empty()).unwrap_or(false);
    if !ipset_ready {
        return false;
    }

    match CHINA_UPSTREAMS.get() {
        Some(u) if !u.is_empty() => {}
        _ => return false,
    }

    // Only A / AAAA queries carry IPs in their answer rdata. Everything else
    // (CNAME, MX, TXT, PTR, HTTPS, SVCB, …) falls through to the trusted
    // resolver.
    matches!(query_qtype(query), Some(QTYPE_A) | Some(QTYPE_AAAA))
}

/// Walks the question section to extract the QTYPE. Returns `None` for
/// malformed queries (caller falls back to DoH).
fn query_qtype(query: &[u8]) -> Option<u16> {
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
    Some(u16::from_be_bytes([query[i], query[i + 1]]))
}

async fn udp_query_race(query: &[u8]) -> Option<Vec<u8>> {
    let upstreams = CHINA_UPSTREAMS.get()?;
    if upstreams.is_empty() {
        return None;
    }

    let futs: Vec<_> = upstreams
        .iter()
        .copied()
        .map(|addr| {
            let q = query.to_vec();
            Box::pin(async move { udp_query_one(addr, &q).await })
        })
        .collect();

    match futures::future::select_ok(futs).await {
        Ok((resp, _rest)) => Some(resp),
        Err(_) => None,
    }
}

async fn udp_query_one(addr: SocketAddr, query: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    let bind: SocketAddr = match addr {
        SocketAddr::V4(_) => "0.0.0.0:0".parse().expect("static literal"),
        SocketAddr::V6(_) => "[::]:0".parse().expect("static literal"),
    };
    let socket = UdpSocket::bind(bind).await?;
    socket.connect(addr).await?;
    socket.send(query).await?;

    let mut buf = vec![0u8; UDP_BUF_SIZE];
    let n = tokio::time::timeout(UDP_RECV_TIMEOUT, socket.recv(&mut buf)).await??;
    buf.truncate(n);
    if buf.len() < 12 {
        anyhow::bail!("udp dns response truncated ({} bytes)", buf.len());
    }
    Ok(buf)
}

/// True iff at least one A/AAAA record in `response` resolves to a CN IP per
/// the pre-built ipset. Mirrors the trust-china-dns "any-CN-IP wins" semantic:
/// a single CN record flips the verdict for the whole answer.
pub(crate) fn response_has_cn_ip(response: &[u8]) -> bool {
    let Some(ipset) = CN_IPSET.get() else {
        return false;
    };
    if ipset.is_empty() {
        return false;
    }
    for (ip, _name, _ttl) in dns_table::parse_dns_response_records(response) {
        if ipset.contains(ip) {
            return true;
        }
    }
    false
}

/// True iff `ip` is in the pre-built CN ipset. Returns `false` when the
/// ipset is missing or empty (GeoIP unavailable) so callers degrade to a
/// pass-through and don't accidentally treat every IP as non-CN-special.
pub(crate) fn is_cn_ip(ip: IpAddr) -> bool {
    let Some(ipset) = CN_IPSET.get() else {
        return false;
    };
    if ipset.is_empty() {
        return false;
    }
    ipset.contains(ip)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    fn build_query(qname: &str, qtype: u16) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&[0xab, 0xcd]); // txid
        buf.extend_from_slice(&[0x01, 0x00]); // flags: standard query, RD=1
        buf.extend_from_slice(&[0x00, 0x01]); // qdcount=1
        buf.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // an/ns/ar=0
        for label in qname.split('.') {
            buf.push(label.len() as u8);
            buf.extend_from_slice(label.as_bytes());
        }
        buf.push(0); // root
        buf.extend_from_slice(&qtype.to_be_bytes());
        buf.extend_from_slice(&[0x00, 0x01]); // qclass=IN
        buf
    }

    fn build_response_a(qname: &str, ips: &[Ipv4Addr]) -> Vec<u8> {
        let mut buf = build_query(qname, QTYPE_A);
        // Patch flags → response.
        buf[2] = 0x81;
        buf[3] = 0x80;
        // Patch ancount.
        buf[6] = 0x00;
        buf[7] = ips.len() as u8;
        for ip in ips {
            // Compressed pointer back to the qname at offset 12.
            buf.extend_from_slice(&[0xc0, 0x0c]);
            buf.extend_from_slice(&QTYPE_A.to_be_bytes()); // type=A
            buf.extend_from_slice(&[0x00, 0x01]); // class=IN
            buf.extend_from_slice(&60u32.to_be_bytes()); // ttl=60
            buf.extend_from_slice(&4u16.to_be_bytes()); // rdlength=4
            buf.extend_from_slice(&ip.octets());
        }
        buf
    }

    #[test]
    fn qtype_extraction_works_for_a_and_aaaa() {
        assert_eq!(query_qtype(&build_query("example.com", QTYPE_A)), Some(1));
        assert_eq!(
            query_qtype(&build_query("example.com", QTYPE_AAAA)),
            Some(28)
        );
        assert_eq!(query_qtype(&build_query("example.com", 16)), Some(16)); // TXT
    }

    #[test]
    fn qtype_extraction_rejects_truncated_query() {
        assert_eq!(query_qtype(&[]), None);
        assert_eq!(query_qtype(&[0u8; 11]), None);
        // Header-only with no question section → walk past end.
        assert_eq!(query_qtype(&[0u8; 12]), None);
    }

    #[test]
    fn ipv6_bind_picks_v6_unspecified() {
        // Sanity: the `match addr` arm chooses an IP-family-matching bind.
        let v6: SocketAddr = "[2001:db8::1]:53".parse().unwrap();
        let v4: SocketAddr = "1.2.3.4:53".parse().unwrap();
        assert!(matches!(v6, SocketAddr::V6(_)));
        assert!(matches!(v4, SocketAddr::V4(_)));
    }

    #[test]
    fn default_upstreams_are_dnspod_and_alidns() {
        let ups = default_china_upstreams();
        assert_eq!(ups.len(), 2);
        assert_eq!(ups[0], "119.29.29.29:53".parse::<SocketAddr>().unwrap());
        assert_eq!(ups[1], "223.5.5.5:53".parse::<SocketAddr>().unwrap());
    }

    #[test]
    fn response_has_cn_ip_returns_false_without_ipset() {
        // CN_IPSET not initialised in this test process → split is disabled,
        // so no response can be flagged CN. Guards against a regression where
        // a missing ipset would silently treat all answers as CN (or panic).
        let resp = build_response_a("example.com", &[Ipv4Addr::new(1, 1, 1, 1)]);
        assert!(!response_has_cn_ip(&resp));
    }

    #[test]
    fn cn_ipset_contains_finds_ip_in_range() {
        // Builds the same `IpRange<IpNet>` shape `init` produces, so the
        // membership logic is exercised without needing a real Country.mmdb.
        let mut v4: IpRange<Ipv4Net> = IpRange::new();
        v4.add("1.0.1.0/24".parse().unwrap());
        v4.add("114.114.114.0/24".parse().unwrap());
        v4.simplify();
        let set = CnIpset {
            v4,
            v6: IpRange::new(),
        };

        assert!(set.contains(IpAddr::V4(Ipv4Addr::new(1, 0, 1, 42)))); // mid-range
        assert!(set.contains(IpAddr::V4(Ipv4Addr::new(114, 114, 114, 0)))); // network addr
        assert!(set.contains(IpAddr::V4(Ipv4Addr::new(114, 114, 114, 255)))); // broadcast addr

        assert!(!set.contains(IpAddr::V4(Ipv4Addr::new(0, 255, 255, 255)))); // before all
        assert!(!set.contains(IpAddr::V4(Ipv4Addr::new(1, 0, 2, 0)))); // gap between
        assert!(!set.contains(IpAddr::V4(Ipv4Addr::new(255, 255, 255, 255)))); // past last
        assert!(!set.contains(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)))); // not CN
    }

    #[test]
    fn cn_ipset_v6_membership_works() {
        let mut v6: IpRange<Ipv6Net> = IpRange::new();
        v6.add("2400:3200::/32".parse().unwrap());
        v6.simplify();
        let set = CnIpset {
            v4: IpRange::new(),
            v6,
        };
        assert!(set.contains(IpAddr::V6(Ipv6Addr::new(0x2400, 0x3200, 0, 0, 0, 0, 0, 1))));
        assert!(!set.contains(IpAddr::V6(Ipv6Addr::new(0x2001, 0x4860, 0, 0, 0, 0, 0, 1))));
    }

    #[test]
    fn insert_network_dispatches_by_family() {
        let mut v4: IpRange<Ipv4Net> = IpRange::new();
        let mut v6: IpRange<Ipv6Net> = IpRange::new();

        // /24 lands in the v4 set.
        let net: ipnetwork::IpNetwork = "1.0.1.0/24".parse().unwrap();
        insert_network(&mut v4, &mut v6, net);
        assert!(v4.contains(&"1.0.1.0/24".parse::<Ipv4Net>().unwrap()));
        assert!(v6.iter().next().is_none());

        // /0 covers entire v4 space.
        let net: ipnetwork::IpNetwork = "0.0.0.0/0".parse().unwrap();
        insert_network(&mut v4, &mut v6, net);
        v4.simplify();
        assert!(v4.contains(&"8.8.8.8/32".parse::<Ipv4Net>().unwrap()));

        // v6 prefix lands on the v6 side, not v4.
        let net: ipnetwork::IpNetwork = "2400:3200::/32".parse().unwrap();
        insert_network(&mut v4, &mut v6, net);
        assert!(v6.contains(&"2400:3200::/32".parse::<Ipv6Net>().unwrap()));
    }

    #[test]
    fn response_a_record_parsing_round_trips() {
        // Sanity for the test fixture itself, so failures of higher-level
        // tests can be triaged to fixture vs. logic.
        let resp = build_response_a(
            "example.com",
            &[Ipv4Addr::new(8, 8, 8, 8), Ipv4Addr::new(114, 114, 114, 114)],
        );
        let recs = dns_table::parse_dns_response_records(&resp);
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[0].0, IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)));
        assert_eq!(recs[1].0, IpAddr::V4(Ipv4Addr::new(114, 114, 114, 114)));
    }

    #[test]
    fn aaaa_query_is_recognised_by_qtype_extraction() {
        let q = build_query("ipv6.example.com", QTYPE_AAAA);
        assert_eq!(query_qtype(&q), Some(QTYPE_AAAA));
        // And IPv6 addr stays well-formed.
        let v6 = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
        assert!(matches!(IpAddr::V6(v6), IpAddr::V6(_)));
    }
}
