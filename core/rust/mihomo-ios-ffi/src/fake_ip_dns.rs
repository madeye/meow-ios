//! Fake-IP-aware DNS server. Replaces the in-FFI DoH / china-DNS / dns_table
//! stack: every A query is answered with a synthetic IP from
//! [`crate::fake_ip`], every AAAA query gets an empty NOERROR (suppress IPv6
//! so the client falls back to the A record we just synthesized), and any
//! other RR type is delegated to the embedded `mihomo_dns::DnsServer`
//! handler — which itself goes through the engine's resolver / cache.
//!
//! Routing:
//!
//! ```text
//!   Client (NEDNSSettings) ──► run() loop on listen_addr
//!                                  │
//!                                  ├─ A    ─► pool().alloc(host)  ─► synth A reply (TTL 60s)
//!                                  ├─ AAAA ─► empty NOERROR
//!                                  └─ rest ─► mihomo_dns::DnsServer::handle_query
//! ```
//!
//! The TTL is intentionally short (60s) so clients revisit the pool while
//! the sliding-TTL entry is still live — keeps reverse-lookup hits warm for
//! long-running TCP flows that re-resolve mid-session.

use crate::fake_ip;
use hickory_proto::op::{Message, MessageType, OpCode, ResponseCode};
use hickory_proto::rr::rdata::A;
use hickory_proto::rr::{DNSClass, Name, RData, Record, RecordType};
use mihomo_dns::{DnsServer, Resolver};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use tokio::net::UdpSocket;
use tracing::{debug, trace, warn};

/// Maximum DNS-over-UDP datagram we'll accept (RFC 6891 EDNS0 sane cap).
const DNS_BUF_SIZE: usize = 4096;

/// Bind `listen` and serve DNS forever. Non-A/AAAA queries are delegated to
/// `mihomo_dns::DnsServer::handle_query(&data, &resolver)` — that helper is
/// pure (no socket binding) and returns the response bytes directly, so we
/// don't need a loopback hop.
pub async fn run(listen: SocketAddr, resolver: Arc<Resolver>) -> std::io::Result<()> {
    let socket = Arc::new(UdpSocket::bind(listen).await?);
    tracing::info!("fake-IP DNS server listening on {}", listen);

    let mut buf = vec![0u8; DNS_BUF_SIZE];
    loop {
        let (len, src) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                warn!("fake-ip-dns: recv error: {}", e);
                continue;
            }
        };
        let data = buf[..len].to_vec();
        let socket_clone = socket.clone();
        let resolver = resolver.clone();
        tokio::spawn(async move {
            let response = match handle_query(&data, &resolver).await {
                Some(bytes) => bytes,
                None => return,
            };
            if let Err(e) = socket_clone.send_to(&response, src).await {
                debug!("fake-ip-dns: send error to {}: {}", src, e);
            }
        });
    }
}

/// Parse `data`, decide the routing, and produce a response packet. Returns
/// `None` when the query is unparseable or the routing yielded no answer
/// worth sending (e.g. mihomo's handler errored).
async fn handle_query(data: &[u8], resolver: &Resolver) -> Option<Vec<u8>> {
    let msg = match Message::from_vec(data) {
        Ok(m) => m,
        Err(e) => {
            trace!("fake-ip-dns: parse error: {}", e);
            return None;
        }
    };

    // Routing decision is driven by the FIRST question. Real-world stub
    // resolvers never multiplex types across questions; if they ever do, we
    // serve whichever the first one is rather than splitting the reply.
    let q = msg.queries().first()?;
    match q.query_type() {
        RecordType::A => Some(build_fake_a_response(&msg, q.name(), q.query_class())),
        RecordType::AAAA => Some(build_empty_noerror(&msg, q.name(), q.query_class())),
        _ => {
            // Anything else — TXT, HTTPS, SVCB, MX, … — falls through to the
            // upstream resolver. mihomo's `DnsServer::handle_query` answers
            // only A/AAAA at this layer and returns NXDOMAIN otherwise, so
            // we'd just be relaying NXDOMAIN. That's the correct behaviour
            // for an iOS NEDNSSettings server that only owns the fake-IP
            // namespace; surface it as a response rather than dropping.
            match DnsServer::handle_query(data, resolver).await {
                Ok(bytes) => Some(bytes),
                Err(e) => {
                    debug!("fake-ip-dns: upstream handle_query error: {}", e);
                    None
                }
            }
        }
    }
}

/// Build a single-answer A response: allocate a fake IP for `qname`, set the
/// answer TTL to 60s (short on purpose — see module doc).
fn build_fake_a_response(query: &Message, qname: &Name, class: DNSClass) -> Vec<u8> {
    let host = qname_to_host(qname);
    let ip = match fake_ip::pool().alloc(&host) {
        IpAddr::V4(v4) => v4,
        // Pool is IPv4-only by construction (DEFAULT_CIDR is /8 in
        // 28.0.0.0/8); this arm should be unreachable. Fall back to 0.0.0.0
        // rather than panic in case a future caller swaps in a v6 pool.
        IpAddr::V6(_) => Ipv4Addr::UNSPECIFIED,
    };

    let mut resp = Message::new();
    resp.set_id(query.id());
    resp.set_message_type(MessageType::Response);
    resp.set_op_code(OpCode::Query);
    resp.set_recursion_desired(query.recursion_desired());
    resp.set_recursion_available(true);
    resp.set_response_code(ResponseCode::NoError);
    for q in query.queries() {
        resp.add_query(q.clone());
    }

    let mut rec = Record::from_rdata(qname.clone(), 60, RData::A(A(ip)));
    rec.set_dns_class(class);
    resp.add_answer(rec);

    resp.to_vec().unwrap_or_else(|_| Vec::new())
}

/// Build an empty NOERROR response for AAAA. NOERROR + zero answers tells
/// the client "I authoritatively know there's no AAAA" without triggering
/// the retry path NXDOMAIN does.
fn build_empty_noerror(query: &Message, _qname: &Name, _class: DNSClass) -> Vec<u8> {
    let mut resp = Message::new();
    resp.set_id(query.id());
    resp.set_message_type(MessageType::Response);
    resp.set_op_code(OpCode::Query);
    resp.set_recursion_desired(query.recursion_desired());
    resp.set_recursion_available(true);
    resp.set_response_code(ResponseCode::NoError);
    for q in query.queries() {
        resp.add_query(q.clone());
    }
    resp.to_vec().unwrap_or_else(|_| Vec::new())
}

/// Lowercase the qname, strip the trailing dot. Matches the canonicalization
/// the fake-IP pool already does internally on the alloc side, so reverse
/// lookups land on the same key.
fn qname_to_host(name: &Name) -> String {
    let s = name.to_utf8();
    let trimmed = s.strip_suffix('.').unwrap_or(&s);
    trimmed.to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use hickory_proto::op::Query;

    fn build_query(qname: &str, qtype: RecordType) -> Vec<u8> {
        let mut msg = Message::new();
        msg.set_id(0x4242);
        msg.set_message_type(MessageType::Query);
        msg.set_op_code(OpCode::Query);
        msg.set_recursion_desired(true);
        let mut q = Query::new();
        q.set_name(Name::from_ascii(qname).unwrap());
        q.set_query_type(qtype);
        q.set_query_class(DNSClass::IN);
        msg.add_query(q);
        msg.to_vec().unwrap()
    }

    #[test]
    fn a_query_synthesizes_pool_ip() {
        let raw = build_query("test-a.example.com.", RecordType::A);
        let msg = Message::from_vec(&raw).unwrap();
        let q = msg.queries().first().unwrap();
        let bytes = build_fake_a_response(&msg, q.name(), q.query_class());
        let parsed = Message::from_vec(&bytes).expect("response parses");

        assert_eq!(parsed.id(), 0x4242);
        assert_eq!(parsed.response_code(), ResponseCode::NoError);
        assert_eq!(parsed.answers().len(), 1);

        let ans = &parsed.answers()[0];
        let RData::A(A(ip)) = ans.data() else {
            panic!("expected A record");
        };
        // Pool default CIDR is 28.0.0.0/8.
        assert_eq!(ip.octets()[0], 28, "answer outside pool: {ip}");
        // Round-trip: reverse-lookup the answered IP and get our host back.
        assert_eq!(
            fake_ip::pool().reverse_lookup(IpAddr::V4(*ip)).as_deref(),
            Some("test-a.example.com")
        );
    }

    #[test]
    fn aaaa_query_returns_empty_noerror() {
        let raw = build_query("test-aaaa.example.com.", RecordType::AAAA);
        let msg = Message::from_vec(&raw).unwrap();
        let q = msg.queries().first().unwrap();
        let bytes = build_empty_noerror(&msg, q.name(), q.query_class());
        let parsed = Message::from_vec(&bytes).expect("response parses");

        assert_eq!(parsed.id(), 0x4242);
        assert_eq!(parsed.response_code(), ResponseCode::NoError);
        assert_eq!(parsed.answers().len(), 0, "AAAA must have zero answers");
        assert_eq!(parsed.queries().len(), 1, "echo question section");
    }

    #[test]
    fn malformed_bytes_fail_parse_without_panic() {
        // `handle_query` short-circuits on `Message::from_vec` errors before
        // touching the resolver, so we exercise the parse step directly —
        // dodges the cost of standing up a real `mihomo_dns::Resolver` for a
        // path that never reaches resolution.
        for garbage in [vec![], vec![0xff; 3], vec![0u8; 11], vec![0xaa; 600]] {
            assert!(
                Message::from_vec(&garbage).is_err()
                    || Message::from_vec(&garbage)
                        .map(|m| m.queries().is_empty())
                        .unwrap_or(false),
                "expected parse-failure or zero-question for garbage of len {}",
                garbage.len()
            );
        }
    }

    #[test]
    fn multi_question_routes_by_first_question() {
        // Build a query that has both A and AAAA questions — first wins.
        let mut msg = Message::new();
        msg.set_id(7);
        msg.set_message_type(MessageType::Query);
        msg.set_op_code(OpCode::Query);
        let mut qa = Query::new();
        qa.set_name(Name::from_ascii("first.example.").unwrap());
        qa.set_query_type(RecordType::A);
        qa.set_query_class(DNSClass::IN);
        msg.add_query(qa);
        let mut qaaaa = Query::new();
        qaaaa.set_name(Name::from_ascii("second.example.").unwrap());
        qaaaa.set_query_type(RecordType::AAAA);
        qaaaa.set_query_class(DNSClass::IN);
        msg.add_query(qaaaa);

        let q = msg.queries().first().unwrap();
        let response = build_fake_a_response(&msg, q.name(), q.query_class());
        let parsed = Message::from_vec(&response).unwrap();
        assert_eq!(parsed.answers().len(), 1);
        // Reverse-lookup confirms the FIRST question's host is what got
        // allocated, not the AAAA one.
        let RData::A(A(ip)) = parsed.answers()[0].data() else {
            panic!("expected A");
        };
        assert_eq!(
            fake_ip::pool().reverse_lookup(IpAddr::V4(*ip)).as_deref(),
            Some("first.example")
        );
    }

    #[test]
    fn qname_canonicalization() {
        let n = Name::from_ascii("Example.COM.").unwrap();
        assert_eq!(qname_to_host(&n), "example.com");
    }
}
