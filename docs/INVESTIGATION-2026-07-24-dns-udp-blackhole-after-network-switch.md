# DNS resolution blackhole after 5G→WiFi switch ("断网 2 分钟自愈")

**Date:** 2026-07-24
**Investigator:** Kimi Code CLI driven by gang
**Status:** DEFERRED — documented for later; not a core issue. Evidence is
complete; fix not implemented.
**Related:** `INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md`
(same family of iOS NECP transient failures, that time on DIRECT TCP dials)

## TL;DR

After an automatic 5G→WiFi network switch, **all** uncached DNS lookups
from the engine's internal resolver fail for ~2 minutes (UDP/53 to
119.29.29.29 / 223.5.5.5 blackholed), while TCP (Trojan proxy) recovers
within seconds. Because fake-ip mode makes every app connection depend on
post-hoc domain resolution, the DNS outage cascades into a **total
connectivity outage for new connections** — the user-perceived "网络连不上".
It self-heals as soon as the NECP/routing transient settles. This is an
iOS network-transition transient, not a DNS server or carrier outage.

## Symptom timeline (2026-07-24, times local UTC+8)

- ~20:25: user arrives home; phone auto-switches 5G → WiFi.
- 20:27:33–20:29: total connectivity loss for new connections.
- ~20:29: self-recovery. Same pattern observed twice that day.

## Evidence (meow-tunnel-20260724-203303.log, exported via in-app log export)

Tunnel log timestamps are UTC; episode window = 12:27:33–12:29:00 UTC.

1. **Wholesale resolve failure.** 273 failures at 12:27, 198 at 12:28,
   1 at 12:29 of `SOCKS5 dial error: DNS error: direct: failed to resolve
   <host>` — across *all* domains (Apple Push, zijieapi/amemv, qq.com,
   taobao, ele.me — no pattern by domain owner).
2. **Cache still served.** `lazy resolve`/`pre_resolve` successes in the
   same window: 4 (12:27), 10 (12:28), then 68 (12:29) after recovery.
   `Resolver::resolve_ips` checks the cache first (resolver.rs:795), so
   the few successes are cache hits; every actual upstream lookup failed.
3. **TCP unaffected.** 27 `Trojan connecting ... via 175.178.178.137:4006`
   in the window; relays closing with real traffic (up to 171 KB down).
   Physical path was fine for TCP.
4. **Cascade to total outage.** Resolve failure → direct outbound dial
   hangs → `mixed-listener dial deadline exceeded ... after 10000 ms;
   dropping flow` at the tun2socks layer for many unrelated destinations
   → apps see total failure.

## Mechanism chain

```
5G→WiFi switch
  → iOS NECP/routing transient for the NE provider's egress
  → engine's UDP/53 queries (119.29.29.29, 223.5.5.5) blackholed ~2 min
  → Resolver::resolve_ips → None for every uncached host
  → DirectAdapter::resolve_targets → "direct: failed to resolve"
  → listener dials hang → tun2socks 10 s dial deadline → flows dropped
  → user: full connectivity loss → transient settles → self-heal
```

Why UDP suffers longer than TCP on a path switch: TCP redials succeed
within seconds (Trojan recovered immediately in the log); the NECP
transient window for new UDP flows lasted ~2 minutes. Same failure
family as the May DIRECT-dial hangs (see Related) — that investigation
already coined "iOS routing-cache transients" and led to
`DirectAdapter::with_connect_timeout`.

## Key code references

- Nameservers are **pinned by the FFI**, not user config:
  `core/rust/meow-ios-ffi/src/lib.rs` (`meow_patch_config`) →
  `nameserver: [119.29.29.29, 223.5.5.5]` (plain UDP/53).
- `meow-rs` (madeye/meow-rs @ 74e8083a):
  - `crates/meow-dns/src/resolver.rs:795` — `resolve_ips` (hosts → cache
    → `lookup_actual_all`).
  - `crates/meow-dns/src/client.rs` — `DnsClient::udp`; a **fresh socket
    per query** (`bind_udp` + `connect()`), so a stuck persistent socket
    is ruled out; per-query timeout exists (3 s at resolver.rs:641).
  - `crates/meow-proxy/src/direct.rs:86` — the exact error string;
    direct outbound depends on the internal resolver (no OS-resolver
    fallback in production).
- resolver.rs:37 notes DoT/DoH-through-proxy is not implemented.

## Reproduction

Leave WiFi (phone on 5G), return home, let it auto-join WiFi. Expect
~2 min of resolve failures. Attach `idevicesyslog` capture or use the
in-app log export to confirm the `failed to resolve` burst signature.

## Fix directions (when revisited)

1. **Transport fallback in the resolver (primary).** On UDP query
   timeout, retry via TCP/53 (Tcp transport already exists in
   `DnsClient`) or DoH. TCP was proven alive during the UDP blackout, so
   this alone makes resolution survive NECP transients.
2. **Path-change reset (hardening).** Engine listens to NE path-change
   notifications and proactively resets resolver transports / flushes
   negative state instead of waiting for timeouts to converge.
3. **Not causes, ruled out:** DNS server outage (two independent servers
   failing simultaneously for exactly the transient window), persistent
   UDP socket stuck (fresh socket per query), QUIC block (drops only
   UDP/443; unrelated to port 53), proxy/upstream health.

## Side observation (also deferred)

The UI "屏蔽 QUIC" toggle implements a **silent drop** of outbound
UDP/443 (`tun2socks: block-HTTP3 on, dropping outbound UDP/443 (QUIC)`).
A silent drop still forces apps to wait out their own H3 handshake
timeout (seconds, with QUIC Initial retransmits) before TCP fallback.
Synthesizing an ICMP port-unreachable back to the app would make H3
fail fast (ECONNREFUSED in milliseconds).

Benefits, when revisited:

- **Latency:** no per-attempt multi-second stall before TCP fallback.
- **Tunnel session-table pressure (the bigger win):** each dropped QUIC
  attempt currently occupies a UDP session entry until the 10 s
  first-reply deadline evicts it. During app retry bursts these
  zombie entries were a real contributor to the "Mixed listener
  saturated at 256 concurrent connections" storms observed on
  2026-07-23. Fail-fast ICMP would let those sessions die immediately,
  and shorter H3 failure means shorter app retry storms overall.

Not about saving TCP ports (QUIC is UDP; the TCP fallback costs the
same either way). Not urgent — modern stacks race H3/TCP via Happy
Eyeballs, so user-visible impact varies by app — and unrelated to the
DNS episode above.
