//! Fake-IP pool for the meow-ios FFI crate.
//!
//! Owns a private-CIDR allocator that hands out synthetic IPv4 addresses to
//! DNS clients (Clash-style) and supports reverse lookup so tun2socks can
//! restore the original hostname before dispatching a flow into mihomo. This
//! replaces the v0.5-era `dns_table` (which stored *real* IPs returned by the
//! in-FFI DoH/CN-DNS client) with a true fake-IP allocator. A/AAAA queries
//! are answered synthetically by [`crate::fake_ip_dns::handle_query`] and
//! never reach `mihomo_dns::DnsServer`; only other RR types (TXT, HTTPS,
//! SVCB, MX, …) delegate to the upstream resolver.
//!
//! Default CIDR: `28.0.0.0/8` (mihomo-party convention — avoids both
//! carrier-grade NAT `100.64/10` and the IETF benchmarking range `198.18/15`
//! that Clash uses by default and that some corporate networks intercept).
//!
//! Semantics
//! ---------
//!  - **Stable while live.** `alloc(host)` is idempotent: repeated calls with
//!    the same hostname return the same fake IP until the mapping is evicted.
//!  - **Sliding TTL.** Both `alloc` and `reverse_lookup` refresh the
//!    last-touched timestamp + LRU recency. A TCP/UDP flow that keeps
//!    touching the fake IP keeps its mapping alive.
//!  - **LRU eviction on pool exhaustion.** When the CIDR is full, the
//!    least-recently-used entry is recycled — Clash-compatible. Callers do
//!    not see allocation failures unless the pool is configured pathologically
//!    small (< 1 usable address).
//!  - **`.0` / `.255` skipped per /24.** Mirrors Clash so traffic to typical
//!    network/broadcast addresses inside the pool isn't accidentally claimed
//!    by a hostname.

use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// Process-global pool. Initialized on first access with `with_defaults`;
/// engine start can pre-warm with a config-driven CIDR via [`init_pool`].
static POOL: OnceLock<FakeIpPool> = OnceLock::new();

/// Return the process-wide fake-IP pool, initializing with module defaults
/// if `init_pool` has not been called yet.
pub(crate) fn pool() -> &'static FakeIpPool {
    POOL.get_or_init(FakeIpPool::with_defaults)
}

/// One-shot initializer for the process-wide pool. Always returns `Ok` —
/// the underlying `OnceLock::set` is a silent no-op when the pool was
/// already initialized (the existing instance is kept). Call at engine start
/// before any DNS traffic. The `Result` is kept on the signature so a future
/// migration to a re-init-able pool can surface failure without a churning
/// API change; callers currently discard the return.
pub(crate) fn init_pool(cidr: &str, ttl: Duration) -> Result<(), FakeIpError> {
    let p = FakeIpPool::new(cidr, ttl)?;
    POOL.set(p).map_err(|_| ()).ok();
    Ok(())
}

/// Default fake-IP pool TTL. 10 minutes matches Clash's default and is long
/// enough that a sliding-TTL design won't churn under steady traffic.
pub const DEFAULT_TTL: Duration = Duration::from_secs(600);

/// Default fake-IP CIDR (mihomo-party convention, see module docs).
pub const DEFAULT_CIDR: &str = "28.0.0.0/8";

#[derive(Debug)]
pub(crate) enum FakeIpError {
    InvalidCidr(String),
    EmptyPool(String),
}

impl std::fmt::Display for FakeIpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FakeIpError::InvalidCidr(s) => write!(f, "invalid CIDR `{s}`"),
            FakeIpError::EmptyPool(s) => write!(
                f,
                "CIDR `{s}` has no usable host addresses after reserving network/broadcast"
            ),
        }
    }
}

impl std::error::Error for FakeIpError {}

/// CIDR-backed allocator. Cheaply clonable via `Arc` at the caller.
pub(crate) struct FakeIpPool {
    inner: Mutex<Inner>,
}

struct Inner {
    /// Inclusive lower bound, in u32 form.
    first: u32,
    /// Inclusive upper bound, in u32 form.
    last: u32,
    /// Round-robin cursor for the *next* candidate when the pool isn't yet
    /// full. Always in `[first, last]`. Wraps to `first` when it exceeds
    /// `last`.
    cursor: u32,
    /// Sliding-TTL window. Mappings whose `last_touched + ttl < now` are
    /// considered expired and are recycled on the next allocation pass.
    ttl: Duration,

    host_to_ip: HashMap<String, Ipv4Addr>,
    ip_to_entry: HashMap<Ipv4Addr, Entry>,
    /// LRU order: front = least-recently-touched, back = most-recently-touched.
    /// Invariant: every IP in `ip_to_entry` appears exactly once here.
    lru: VecDeque<Ipv4Addr>,
}

struct Entry {
    host: String,
    last_touched: Instant,
}

impl FakeIpPool {
    /// Create a pool over `cidr` (IPv4 only) with the given sliding-TTL.
    pub fn new(cidr: &str, ttl: Duration) -> Result<Self, FakeIpError> {
        let (first, last) = parse_ipv4_cidr(cidr)?;
        if last <= first {
            return Err(FakeIpError::EmptyPool(cidr.to_string()));
        }
        // Reserve network (.first) and broadcast (.last) of the CIDR itself.
        let lo = first + 1;
        let hi = last - 1;
        if hi < lo {
            return Err(FakeIpError::EmptyPool(cidr.to_string()));
        }
        Ok(Self {
            inner: Mutex::new(Inner {
                first: lo,
                last: hi,
                cursor: lo,
                ttl,
                host_to_ip: HashMap::new(),
                ip_to_entry: HashMap::new(),
                lru: VecDeque::new(),
            }),
        })
    }

    /// Pool with the meow-ios defaults (`28.0.0.0/8`, 10-minute sliding TTL).
    pub fn with_defaults() -> Self {
        Self::new(DEFAULT_CIDR, DEFAULT_TTL).expect("default CIDR is valid")
    }

    /// Allocate (or refresh) a fake IPv4 for `host`. Always succeeds for a
    /// non-pathological pool — when the CIDR is full, the least-recently-used
    /// mapping is recycled.
    pub fn alloc(&self, host: &str) -> IpAddr {
        self.alloc_at(host, Instant::now())
    }

    /// Reverse-lookup `ip` to the hostname that allocated it, refreshing the
    /// mapping's sliding TTL on hit. Returns `None` for an IP outside the
    /// pool, an unallocated slot, or an entry that has aged past TTL.
    pub fn reverse_lookup(&self, ip: IpAddr) -> Option<String> {
        self.reverse_lookup_at(ip, Instant::now())
    }

    /// Number of currently-live mappings. Test-only — diagnostics use the
    /// existing tracing log lines rather than polling this counter, and
    /// production has no caller for it.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.inner.lock().host_to_ip.len()
    }

    /// Test seam: same as [`alloc`] with an injected clock.
    pub(crate) fn alloc_at(&self, host: &str, now: Instant) -> IpAddr {
        let mut g = self.inner.lock();
        g.evict_expired(now);

        // Hot path: existing mapping, just refresh.
        if let Some(&ip) = g.host_to_ip.get(host) {
            g.touch(ip, now);
            return IpAddr::V4(ip);
        }

        // Cold path: find a free slot, or evict LRU if pool is full.
        let ip = g.next_free_slot().unwrap_or_else(|| {
            // Pool full — evict the least-recently-used entry.
            let victim = g.lru.pop_front().expect("pool full implies lru non-empty");
            if let Some(entry) = g.ip_to_entry.remove(&victim) {
                g.host_to_ip.remove(&entry.host);
            }
            victim
        });

        g.host_to_ip.insert(host.to_string(), ip);
        g.ip_to_entry.insert(
            ip,
            Entry {
                host: host.to_string(),
                last_touched: now,
            },
        );
        g.lru.push_back(ip);
        IpAddr::V4(ip)
    }

    /// Test seam: same as [`reverse_lookup`] with an injected clock.
    pub(crate) fn reverse_lookup_at(&self, ip: IpAddr, now: Instant) -> Option<String> {
        let v4 = match ip {
            IpAddr::V4(v4) => v4,
            IpAddr::V6(_) => return None,
        };
        let mut g = self.inner.lock();
        g.evict_expired(now);
        let host = g.ip_to_entry.get(&v4).map(|e| e.host.clone())?;
        g.touch(v4, now);
        Some(host)
    }

    /// `true` iff `ip` is a fake-IP allocation candidate from this pool's
    /// CIDR (and not in the reserved-octet bands). Callers (tun2socks) use
    /// this to skip the reverse-lookup mutex acquisition on flows whose
    /// destination IP is unambiguously *not* one we synthesized — e.g.
    /// CN-bypass replies that returned a real upstream IP, or clients that
    /// dialed a literal IP directly. A miss inside `reverse_lookup` would
    /// return `None` anyway, but the CIDR check is a cheap pre-filter that
    /// avoids the lock on the (now common, post-CN-bypass) real-IP path.
    pub(crate) fn contains(&self, ip: IpAddr) -> bool {
        let v4 = match ip {
            IpAddr::V4(v4) => v4,
            IpAddr::V6(_) => return false,
        };
        let n = u32::from(v4);
        let g = self.inner.lock();
        n >= g.first && n <= g.last && !is_reserved_octet(v4)
    }
}

impl Inner {
    /// Refresh `ip`'s last-touched timestamp + LRU position. Caller must hold
    /// the mutex.
    fn touch(&mut self, ip: Ipv4Addr, now: Instant) {
        if let Some(entry) = self.ip_to_entry.get_mut(&ip) {
            entry.last_touched = now;
        }
        if let Some(pos) = self.lru.iter().position(|x| *x == ip) {
            self.lru.remove(pos);
        }
        self.lru.push_back(ip);
    }

    /// Drop all entries whose `last_touched + ttl < now`. O(n) but n is
    /// bounded by pool capacity and most callers are I/O-bound anyway.
    fn evict_expired(&mut self, now: Instant) {
        while let Some(&front) = self.lru.front() {
            let expired = self
                .ip_to_entry
                .get(&front)
                .map(|e| now.saturating_duration_since(e.last_touched) > self.ttl)
                .unwrap_or(true);
            if !expired {
                break;
            }
            self.lru.pop_front();
            if let Some(entry) = self.ip_to_entry.remove(&front) {
                self.host_to_ip.remove(&entry.host);
            }
        }
    }

    /// Walk the cursor forward up to `capacity()` steps looking for a slot
    /// not currently in `ip_to_entry`. Returns `None` when the pool is full.
    fn next_free_slot(&mut self) -> Option<Ipv4Addr> {
        let capacity = (self.last - self.first + 1) as u64;
        for _ in 0..capacity {
            let candidate = Ipv4Addr::from(self.cursor);
            // Advance cursor (with wrap) for the next call regardless of
            // whether we pick this slot.
            self.cursor = if self.cursor == self.last {
                self.first
            } else {
                self.cursor + 1
            };
            if is_reserved_octet(candidate) {
                continue;
            }
            if !self.ip_to_entry.contains_key(&candidate) {
                return Some(candidate);
            }
        }
        None
    }
}

/// Last octet is `0` (network) or `255` (broadcast) in the host's enclosing
/// /24 — skip these to mirror Clash. Cheap relative to the hashmap lookup it
/// gates.
fn is_reserved_octet(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    octets[3] == 0 || octets[3] == 255
}

/// Parse `A.B.C.D/N` into the inclusive `[first, last]` u32 bounds of the
/// CIDR. Pulled out so we don't take a dependency on `ipnet`/`cidr` for
/// what's a four-line bit-twiddle.
fn parse_ipv4_cidr(s: &str) -> Result<(u32, u32), FakeIpError> {
    let (addr_s, prefix_s) = s
        .split_once('/')
        .ok_or_else(|| FakeIpError::InvalidCidr(s.to_string()))?;
    let addr: Ipv4Addr = addr_s
        .parse()
        .map_err(|_| FakeIpError::InvalidCidr(s.to_string()))?;
    let prefix: u8 = prefix_s
        .parse()
        .map_err(|_| FakeIpError::InvalidCidr(s.to_string()))?;
    if prefix > 32 {
        return Err(FakeIpError::InvalidCidr(s.to_string()));
    }
    let base = u32::from(addr);
    // `prefix == 0` is degenerate but technically valid; saturate the mask.
    let mask = if prefix == 0 {
        0u32
    } else {
        u32::MAX << (32 - prefix as u32)
    };
    let first = base & mask;
    let last = first | !mask;
    Ok((first, last))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn pool(cidr: &str) -> FakeIpPool {
        FakeIpPool::new(cidr, Duration::from_secs(60)).expect("valid pool")
    }

    /// A "now" that we can advance by hand; cheaper than sleeping for TTL
    /// tests and deterministic on slow CI.
    fn t0() -> Instant {
        Instant::now()
    }

    // -- 1. Allocation basics ------------------------------------------------

    #[test]
    fn alloc_returns_ip_inside_cidr() {
        let p = pool("28.0.0.0/8");
        let ip = p.alloc("example.test");
        assert!(p.contains(ip), "{ip} not in pool");
        match ip {
            IpAddr::V4(v4) => assert_eq!(v4.octets()[0], 28),
            _ => panic!("v4 expected"),
        }
    }

    #[test]
    fn alloc_is_stable_for_same_host() {
        let p = pool("28.0.0.0/8");
        let a = p.alloc("example.test");
        let b = p.alloc("example.test");
        let c = p.alloc("example.test");
        assert_eq!(a, b);
        assert_eq!(b, c);
        assert_eq!(p.len(), 1);
    }

    #[test]
    fn alloc_gives_distinct_ips_to_distinct_hosts() {
        let p = pool("28.0.0.0/8");
        let a = p.alloc("a.example");
        let b = p.alloc("b.example");
        let c = p.alloc("c.example");
        assert_ne!(a, b);
        assert_ne!(b, c);
        assert_ne!(a, c);
        assert_eq!(p.len(), 3);
    }

    #[test]
    fn alloc_skips_dot_zero_and_dot_255() {
        // /28 → 16 raw, 14 host slots, then minus the per-/24 .0/.255 if
        // the range straddles one. 28.0.0.0/28 spans 28.0.0.0..=28.0.0.15
        // → reserved network (.0) and broadcast (.15) at the CIDR boundary
        // get reserved by the constructor; .0 (last octet) is also caught
        // by `is_reserved_octet` for any future range that includes it.
        let p = pool("28.0.0.0/28");
        let mut seen = Vec::new();
        for i in 0..14 {
            let ip = p.alloc(&format!("h{i}.example"));
            seen.push(ip);
            assert!(p.contains(ip));
            if let IpAddr::V4(v4) = ip {
                let o = v4.octets();
                assert_ne!(o[3], 0, "got .0 address {v4}");
                assert_ne!(o[3], 255, "got .255 address {v4}");
            }
        }
        // 14 distinct addresses for 14 hosts in a /28 with network +
        // broadcast reserved.
        let unique: std::collections::HashSet<_> = seen.iter().collect();
        assert_eq!(unique.len(), seen.len());
    }

    // -- 2. Reverse lookup ---------------------------------------------------

    #[test]
    fn reverse_lookup_roundtrips_host() {
        let p = pool("28.0.0.0/8");
        let ip = p.alloc("roundtrip.test");
        assert_eq!(p.reverse_lookup(ip).as_deref(), Some("roundtrip.test"));
    }

    #[test]
    fn reverse_lookup_misses_for_unallocated_ip() {
        let p = pool("28.0.0.0/8");
        let _ = p.alloc("only.host");
        let unallocated = IpAddr::V4(Ipv4Addr::new(28, 99, 99, 77));
        assert_eq!(p.reverse_lookup(unallocated), None);
    }

    #[test]
    fn reverse_lookup_misses_for_ip_outside_pool() {
        let p = pool("28.0.0.0/8");
        // Real public IP — must never reverse-resolve to a fake-IP host.
        let outside = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));
        assert_eq!(p.reverse_lookup(outside), None);
    }

    #[test]
    fn reverse_lookup_rejects_ipv6() {
        let p = pool("28.0.0.0/8");
        let _ = p.alloc("h.example");
        let v6: IpAddr = "::1".parse().unwrap();
        assert_eq!(p.reverse_lookup(v6), None);
    }

    // -- 3. LRU eviction on pool exhaustion ---------------------------------

    #[test]
    fn lru_evicts_oldest_when_pool_is_full() {
        // /29 → 8 raw, after reserving network + broadcast → 6 usable host
        // slots. Allocate 6, then a 7th — the first allocation must be the
        // one evicted.
        let p = pool("28.0.0.0/29");
        let now = t0();
        let mut allocated = Vec::new();
        for i in 0..6 {
            let ip = p.alloc_at(&format!("h{i}"), now + Duration::from_millis(i as u64));
            allocated.push((format!("h{i}"), ip));
        }
        assert_eq!(p.len(), 6, "pool should be saturated");

        // Bump well past the last touch so the 7th alloc sees a clearly
        // older LRU front. (Still inside TTL — this isn't an expiry test.)
        let new_ip = p.alloc_at("h_new", now + Duration::from_millis(100));

        // The evicted host must have been the oldest one (h0), and h_new
        // must have taken its slot.
        let (_, evicted_ip) = &allocated[0];
        assert_eq!(new_ip, *evicted_ip, "new alloc should recycle the LRU slot");
        // That same IP now reverse-resolves to h_new, not h0 — the recycled
        // mapping has been replaced, not duplicated.
        assert_eq!(
            p.reverse_lookup_at(*evicted_ip, now + Duration::from_millis(101))
                .as_deref(),
            Some("h_new"),
            "evicted IP should now map to h_new"
        );
        // And h0 itself must no longer be allocated: a fresh alloc("h0")
        // returns a brand-new IP (which forces eviction of the NEW LRU
        // front, h1).
        let h0_again = p.alloc_at("h0", now + Duration::from_millis(102));
        assert_ne!(
            h0_again, *evicted_ip,
            "h0 should get a fresh IP after eviction"
        );

        // h2..h5 should still resolve to themselves (untouched by the two
        // evictions: h0 and h1).
        for (host, ip) in &allocated[2..] {
            assert_eq!(
                p.reverse_lookup_at(*ip, now + Duration::from_millis(103))
                    .as_deref(),
                Some(host.as_str())
            );
        }
    }

    #[test]
    fn reverse_lookup_refreshes_lru_position() {
        // Same /29 pool, but this time we touch h0 via reverse_lookup
        // before saturating — h0 should NOT be the eviction victim.
        let p = pool("28.0.0.0/29");
        let now = t0();
        let mut hosts = Vec::new();
        for i in 0..6 {
            let ip = p.alloc_at(&format!("h{i}"), now + Duration::from_millis(i as u64));
            hosts.push((format!("h{i}"), ip));
        }

        // Sliding TTL: lookup on h0 promotes it to MRU.
        let h0_ip = hosts[0].1;
        let _ = p.reverse_lookup_at(h0_ip, now + Duration::from_millis(50));

        // Now allocate a 7th host. h1 is now the oldest unrefreshed entry.
        let _ = p.alloc_at("h_new", now + Duration::from_millis(100));

        // h0 must survive (its mapping was refreshed via reverse_lookup).
        assert_eq!(
            p.reverse_lookup_at(h0_ip, now + Duration::from_millis(101))
                .as_deref(),
            Some("h0"),
            "h0 was touched via reverse_lookup and should not be evicted"
        );
        // h1 must have been recycled: its IP now belongs to h_new.
        let h1_ip = hosts[1].1;
        assert_eq!(
            p.reverse_lookup_at(h1_ip, now + Duration::from_millis(101))
                .as_deref(),
            Some("h_new"),
            "h1 was the new LRU front and h_new should have taken its slot"
        );
    }

    // -- 4. Sliding TTL expiry ----------------------------------------------

    #[test]
    fn entries_expire_past_ttl() {
        let p = FakeIpPool::new("28.0.0.0/24", Duration::from_secs(10)).unwrap();
        let now = t0();
        let ip = p.alloc_at("ephemeral.test", now);
        assert_eq!(
            p.reverse_lookup_at(ip, now + Duration::from_secs(5))
                .as_deref(),
            Some("ephemeral.test")
        );
        // Past TTL with no refresh → expired.
        // Note: the prior reverse_lookup_at refreshed last_touched to
        // `now + 5s`, so we need to jump past *that* + ttl, i.e. now + 16s.
        assert_eq!(
            p.reverse_lookup_at(ip, now + Duration::from_secs(16)),
            None,
            "entry should expire after sliding TTL elapses with no touches"
        );
        assert_eq!(p.len(), 0, "expired entry should be reaped");
    }

    #[test]
    fn alloc_refreshes_ttl() {
        let p = FakeIpPool::new("28.0.0.0/24", Duration::from_secs(10)).unwrap();
        let now = t0();
        let ip1 = p.alloc_at("sticky.test", now);
        // Re-alloc at t = 8s refreshes the entry — at t = 15s (within
        // 10s of the refresh) it must still be live.
        let ip2 = p.alloc_at("sticky.test", now + Duration::from_secs(8));
        assert_eq!(ip1, ip2, "re-alloc should return same IP");
        assert_eq!(
            p.reverse_lookup_at(ip1, now + Duration::from_secs(15))
                .as_deref(),
            Some("sticky.test"),
            "alloc within TTL should slide the window forward"
        );
    }

    // -- 5. CIDR parsing edge cases -----------------------------------------

    #[test]
    fn invalid_cidr_is_rejected() {
        assert!(FakeIpPool::new("not-a-cidr", DEFAULT_TTL).is_err());
        assert!(FakeIpPool::new("28.0.0.0", DEFAULT_TTL).is_err()); // no prefix
        assert!(FakeIpPool::new("28.0.0.0/33", DEFAULT_TTL).is_err());
        assert!(FakeIpPool::new("28.0.0.0/-1", DEFAULT_TTL).is_err());
    }

    #[test]
    fn degenerate_cidrs_rejected_with_empty_pool() {
        // /31 and /32 leave no host slots after reserving network + broadcast.
        assert!(matches!(
            FakeIpPool::new("28.0.0.0/31", DEFAULT_TTL),
            Err(FakeIpError::EmptyPool(_))
        ));
        assert!(matches!(
            FakeIpPool::new("28.0.0.0/32", DEFAULT_TTL),
            Err(FakeIpError::EmptyPool(_))
        ));
    }

    #[test]
    fn defaults_match_module_docs() {
        let p = FakeIpPool::with_defaults();
        let ip = p.alloc("default.test");
        if let IpAddr::V4(v4) = ip {
            assert_eq!(v4.octets()[0], 28, "default CIDR should be 28.0.0.0/8");
        } else {
            panic!("v4 expected");
        }
    }
}
