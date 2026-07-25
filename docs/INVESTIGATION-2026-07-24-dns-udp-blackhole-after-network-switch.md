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

## Side observation → IMPLEMENTED 2026-07-24 (UDP fail-fast rejection)

The UI "屏蔽 QUIC" toggle originally implemented a **silent drop** of
outbound UDP/443. That same evening a second, bigger UDP problem was
identified (next section), and the toggle's semantics were broadened and
implemented as **fail-fast rejection** in
`core/rust/meow-ios-ffi/src/tun2socks.rs`:

- When the toggle is ON, **all non-DNS (non-53) UDP egress** is answered
  with a synthesized **ICMP port-unreachable** instead of being silently
  dropped or forwarded via SOCKS5 UDP ASSOCIATE. Builders:
  `build_icmpv4_port_unreachable` (type 3 code 3, RFC 792 quote) and
  `build_icmpv6_port_unreachable` (type 1 code 4, RFC 4443 pseudo-header
  checksum, quote capped at the 1280-byte min MTU). The raw frame is
  injected via a clone of the TUN `egress_tx` channel (the `udp_write`
  path can only emit UDP), `try_send`, lossy under Swift backpressure.
- **Exemptions:** UDP/53 (DNS, intercepted internally as before) and
  UDP/123 (NTP — iOS `timed`; volume too small to ever pressure the
  listener, and Wi-Fi-only time sync rides this path).
- Toggle OFF preserves the old behaviour exactly. FFI symbol
  `set_block_http3` unchanged (Swift side untouched); only the semantics
  grew — UI label still says "屏蔽 QUIC", a rename is a follow-up.
- Unit tests: 5 builder tests (wire format, checksum residues, v6 quote
  truncation, cross-family rejection). `cargo test tun2socks` = 41 green.

**Known trade-off (accepted):** real-time UDP media apps (FaceTime,
WeChat voice/video, games) use *ephemeral* ports, so they cannot be
port-exempted — with the toggle ON they fail-fast to their TCP/relay
fallbacks with degraded quality. Workflow: flip the toggle off before
such calls. Caveat: with the toggle OFF those calls only work if the
callee/media IPs hit a DIRECT rule — Apple IP ranges routed to the
TCP-only upstream fail regardless (needs an `Apple → DIRECT` rule;
unverified in the current ruleset).

**Future improvement (deferred):** replace the blanket reject with a
**rate-triggered** one — only start rejecting when the UDP new-session
rate exceeds a flood signature threshold (e.g. >30 new dst/s; PCDN
floods run at ~7/s sustained with bursts of 400+/min, normal use is far
below). That would let occasional legitimate UDP through while still
clamping floods.

## 2026-07-24 22:20 iQiyi PCDN UDP flood → mixed-listener saturation

**Symptom:** while watching iQiyi (爱奇艺), recurring stalls; log export
`meow-tunnel-20260724-222220.log` showed 566 `socks5_udp` lines in
2 minutes (peak 416/min) plus `Mixed listener 'mixed' saturated at 256
concurrent connections; new clients will queue` at 14:21:04 UTC.

**Traffic shape:** iQiyi PCDN (P2P CDN, `qchannel01.cn` / HCDN) sprays
UDP at dozens of residential CN IPs on random high ports — 42 unique
dst IPs in the capture. This is NOT QUIC (only 10 of the UDP targets
were :443, already dropped by block-HTTP3).

**Mechanism chain (corrected after source review):**

```
iQiyi PCDN UDP flood (per-dst flows, aggressive retry)
  → tun2socks opens ONE SOCKS5 UDP ASSOCIATE control TCP conn per
    (src,dst) to the mixed listener (open_socks5_udp_session,
    tun2socks.rs:1548)
  → each session lingers 60 s (DEFAULT_UDP_IDLE, meow-rs
    meow-tunnel/src/udp.rs:14)
  → flood rate × 60 s TTL ≥ 256 → listener semaphore exhausted
    (cap is deliberate: ~90 KB userland per conn, meow-listener
    mixed.rs:16)
  → accept stalls → listen backlog fills → NEW connects to
    127.0.0.1:7890 get SYN-dropped → ETIMEDOUT after kernel retries
  → "SOCKS5 UDP ASSOCIATE failed ... Operation timed out (os error 60)"
    AND unrelated normal TCP queues behind the same semaphore → stall
  → PCDN client gives up / TTLs expire → self-heal
```

**Key correction:** the `os error 60` timeouts are the **local**
`TcpStream::connect(127.0.0.1:7890)` timing out (tun2socks.rs:1480) —
NOT an upstream/proxy failure. Routing was verified correct: UDP goes
through the same rule matching as TCP (meow-rs
meow-listener/src/socks5_udp.rs:10 — fake-IP rewrite → port-53 DIRECT
bypass → rule match → `dial_udp`), and these CN IPs matched DIRECT as
intended. The flood killed the tunnel without a single packet reaching
the upstream.

**Fix:** the fail-fast rejection above — non-DNS UDP is now refused
locally in the TUN, costing zero listener connections, and PCDN clients
fall back to TCP CDN immediately. Verification: watch iQiyi with the
toggle ON; expect zero `socks5_udp` sessions and no `saturated` lines.

Not about saving TCP ports (QUIC is UDP; the TCP fallback costs the
same either way).

---

## 2026-07-25 00:45 附记:X 卡死事件(app 级,非隧道故障)

**现象:** 用户报 X 突然无法刷新,爱奇艺/网页均正常。VPN 显示连接。

**排查(syslog, PacketTunnel PID 8681):**

- 隧道进程一直活着,memstats 每秒正常 tick,无 watchdog、无 panic。
- 故障期间隧道里**完全没有** X 的流量:无 twitter/x.com/twimg 的
  DNS query、无 SOCKS5 CONNECT——包根本没进 TUN。
- 其他 App(爱奇艺、网页、甚至 Twitter 进程自己的 CoreMotion 日志)
  都正常 → 隧道和系统路由都没问题。
- **X 重启后立即恢复**,日志里随即出现 api-stream.twitter.com /
  video.twimg.com 的正常连接和数百 KB 下行数据。

**结论:** X 自己持有的连接/会话 wedge 住了,新请求也卡在 app 内部,
根本没发包。重启 app 即清。不是崩溃、不是断流、不是规则问题。

**待观察的假设(未证实):** X 重度依赖 QUIC/HTTP3 长连接。本次故障是
ICMP fail-fast 上线后第一次发生——不能排除 QUIC 路径被 port-unreachable
打断后 X 的连接管理器进入坏状态、且不像浏览器那样自动回退 TCP 的可能。
此前的静默丢包实现下未观察到 X 这种现象(但样本量小,也可能只是
网络切换(5G→WiFi)后的 app 级 stale,与本改动无关)。

**处置约定:** 再遇到"单个 App 不通、其他正常",先查隧道日志里有没有
该 App 的域名;没有 → app 级问题,重启该 App;有 → 再看规则/节点。
若 X 反复出现且确认与 ICMP reject 相关,可考虑对 twitter/x.com 的
UDP/443 退回静默丢包(按域名例外),暂不实施。

## 2026-07-25 07:15 附记:CloudFlare 组指向代理节点的安全性实证

背景:X 无法刷新的根因是 `☁️ CloudFlare` 组(select,默认 DIRECT)
在配置重载后回落 DIRECT,而订阅没有 twitter 域名规则,X 的 API 经
Cloudflare IP-CIDR 规则落入该组 → 直连 Cloudflare IP 被墙 → 挂死。
修复:用户手动把该组指向 `🚀 节点选择`,X 立即恢复。

担心"CN App 是否会被 CloudFlare IP 规则卷进代理"——实测否定:
用户依次打开中国移动/淘宝/京东/支付宝/微信/知乎/小红书/滴滴等,
约 1079 条连接中 1073 条命中 `🎯 全球直连`,**CloudFlare 组命中 0**。
仅 6 条非直连且全部合理:Google DNS(8.8.8.8/8.8.4.4)、AppsFlyer
归因 SDK(appsflyersdk.com)→ 节点选择;jddebug.com → 漏网之鱼。

**遗留真 bug(未修):select 组手动选择在配置重载(订阅更新/隧道
重启)后丢失,回落默认。** 今天的 X 故障就是这样发生的。待办:配置
重载时按组名持久化/恢复用户选择;节点不存在时回落默认。

## 2026-07-25 更新:UDP 全拒改为"QUIC 开关 + UDP 会话预算"双机制

上一版的"屏蔽 QUIC 开关 = 全拒非 DNS UDP"语义过宽(FaceTime/WebRTC/
游戏 UDP 全被误伤)。按用户决策重构,均在 tun2socks.rs,零上游改动:

- **屏蔽 QUIC 开关恢复原语义**:只拒 UDP/443(ICMP port-unreachable
  fail-fast 保留),其他端口不受影响。准入判断在会话查找之前,开关
  中途打开也会掐死已存在的 443 会话。
- **UDP 会话预算(64,无开关)**:每个转发的 UDP 流占监听器一个
  控制连接 60s;live 会话数达 64 后,新流回 ICMP port-unreachable。
  洪峰只烧 UDP 自己的预算,TCP 物理免疫(192 slot 余量)。已存在的
  会话不受预算驱逐,直到自己的 idle TTL/失败回收。
- 准入逻辑抽成纯函数 `udp_flow_admission(toggle, port, live)`,单元
  测试覆盖:开关开只拒 443、开关关全放行、预算满与开关无关、QUIC
  原因优先于预算原因。
- NTP(123)不再需要特判:443 之外本就不拒,123 走正常预算制,
  流量极小不会构成压力。

行为对照:iQiyi PCDN 洪峰 → 前 64 个流放行,其余 ICMP 即拒,监听器
零饱和风险;FaceTime 通话 → 少量 UDP 流正常工作(需目标走 DIRECT
规则,代理域名 UDP 依旧不通,这是上游 TCP-only 的固有限制)。

### 2026-07-25 13:03–13:16 视频 App PCDN 行为对比实测(预算制上线后)

| App | UDP 会话速率 | 撞 64 预算 | 画像 |
|---|---|---|---|
| 腾讯视频 | 1108/3min + 473/min | 114 次 | UDP 打洞(5004/8000/3478 STUN/19700/62778)+ **TCP 并发 ~200 条**双料洪峰 |
| 抖音 / B 站 | 74/min | 12 次 | PCDN 温和,STUN 打洞,闸门轻挡即过 |
| 爱奇艺 | ~30/min | 0 次 | 阵发性,本次涓流(7-24 晚曾风暴) |
| YouTube | 0 | 0 | 仅 QUIC/443 被开关 fail-fast |

**新事件(已接受为物理上限,不修):** 腾讯视频启动引导的 ~200 条并发
TCP(vi.bls.mdt.qq.com 预连接 56、httpdns 119.29.29.98 查询 52、
trace.inlong.qq.com 36……)叠加 ~50 UDP 会话,打满监听器 256 slot,
13:05:52–13:06:03 饱和抖动 11 秒,排队连接 10s 拨号超时被丢,用户感知
全卡;随后自愈。UDP 预算无法覆盖此类 TCP 突发;TCP 是真实业务连接,
不做准入。backlog:评估内存余量后考虑上调监听器 cap(每 conn ~90KB,
扩展 50MB jetsam 限制下需谨慎)。

UDP 预算在三家连测下全部表现正确:抖音/B站无感、腾讯视频 UDP 侧被
驯服、监听器再未因 UDP 饱和。

### 2026-07-25 14:03 闭环:监听器 cap 256→384,实测吞掉腾讯视频突发

改动:engine.rs prepare_ios_config 强制注入 max-connections: 384(订阅
不可覆盖,上游 meow-rs 零改动);lwip MEMP_NUM_TCP_PCB 256→384 配套。

实测(腾讯视频冷启动+播放):tcp_conns 峰值 258(>256,旧 cap 必 flap),
saturated 0 次;内存峰值 footprint 31MB / heap 35.4MB, jetsam 余量 ~30%;
单连接成本实测 (35.4-12)/258 ≈ 90KB,与上游账本一致 → 384 是安全上限,
512 不可行。播放体感丝滑,之前的 11s 卡死窗口消失。

容量模型终态:TCP 保底 320(384-64 UDP 硬顶),弹性 ~380;UDP 硬顶 64;
QUIC 走独立开关。三层:UDP 预算防洪峰 / 384 容量吞突发 / 开关管 H3。
