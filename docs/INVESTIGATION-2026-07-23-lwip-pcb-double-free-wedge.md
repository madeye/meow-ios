# lwip PCB double-free — wedge/crash root cause, fix, and follow-ups

**Date:** 2026-07-23/24 (incident + investigation)
**Investigator:** Kimi Code CLI driven by gang
**Status:** FIX ON DEVICE, pending verification + upstream. This file is the
checklist to resume from.
**Related:** `INVESTIGATION-2026-05-18-tcp-direct-rule-disconnect.md`,
`INVESTIGATION-2026-07-24-dns-udp-blackhole-after-network-switch.md`
(the "连不上自愈" episodes turned out to be a DIFFERENT issue — DNS/UDP
after network switch — documented there, not here)

## TL;DR

lwip had paths that free a TCP pcb **without notifying the application**
(err callback). The Rust tun2socks binding keeps the raw pcb in its
stream object and calls `tcp_close`/`tcp_abort` from `Drop`, guarded by a
`ctx.errored` flag that only the err callback sets. A silently-freed pcb
therefore got `tcp_close`d again from `Drop` → hit the CLOSED branch
(`local_port == 0` → no list removal) → **`tcp_free` twice** → memp
free-list corruption → the same block handed out by two `tcp_alloc`s →
duplicate `TCP_REG` → PCB list cycle (wedged `tcp_input` walk holding
`LWIP_MUTEX` = 断流) or bad-state node (assert crash). Fix: fire the err
callback on those two free paths. **Zero crashes since the fix
(2026-07-24 ~02:00), previously ~15/day.**

## Symptoms (both were the same root cause)

1. **Wedge ("断流"):** VPN shows connected, zero traffic, watchdog often
   unable to recover. Mechanism: duplicate `TCP_REG` creates a list
   cycle; the next `tcp_input` demux walk spins forever holding
   `LWIP_MUTEX`; every lwip-touching thread freezes.
2. **Crashes:** `SIGABRT` on `meow-tun2socks` thread in
   `tcp_input`/`tcp_pcbs_sane`. 15 reports on 2026-07-23, interval
   16–51 min. These appeared once the diagnostic build turned the silent
   spin into a bounded-walk abort.

## Root-cause chain (each link has direct evidence)

1. Rust `TcpStreamImpl::drop` (lwip fork `rust/tcp_stream_impl.rs:206`)
   calls `tcp_abort` or `tcp_close` on the raw pcb unless
   `ctx.errored` (set only by `tcp_err_cb`).
2. **Silent free path 1:** `tcp_input_delayed_close` (tcp_in.c:616)
   skipped `TCP_EVENT_ERR(..., ERR_CLSD)` when `TF_RXCLOSED` was set.
   **Silent free path 2:** `tcp_slowtmr` TIME_WAIT reap (tcp.c tw loop)
   fired no callback at all. (FIN_WAIT_2 slowtmr reap on the *active*
   list does fire ERR — that path was fine.)
3. `Drop` on a silently-freed pcb: stale memory reads `state=CLOSED`,
   `local_port=0` (zeroed by `tcp_pcb_remove` in step 2) →
   `tcp_close_shutdown` CLOSED case skips `TCP_RMV` → `tcp_free` again.
4. Double free → block on memp free list twice → two `tcp_alloc`s return
   it → two owners → duplicate `TCP_REG` / active↔tw list splice.
5. List corruption detonates minutes later in an unrelated `tcp_input`
   walk — which is why crash stacks never pointed at the cause.

### Key evidence

- 2026-07-24 00:43 crash ring: pcb `0x103d39ec0` freed **twice**
  (`f? st=0 lp=0 rp=52769` ×2, no intervening `GA`) → later double-`GA` →
  `TCP_REG: already registered` assert at `tcp_in.c:720`
  (`tcp_listen_input`).
- 2026-07-24 01:48 crash: tw list contained a SYN_RCVD node splicing
  into the whole active list; pcb `0x1061021e8` history shows the second
  free with **`caller=0x1053a05d0` → `tcp_close_shutdown`**, first free
  via `tcp_input_delayed_close`. Caller tagging (`__builtin_return_address`
  in the diag ring) is what nailed the sites.

## The fix (currently ONLY in the local diag fork `/Users/gang/proj/lwip-diag`)

1. `old-src/core/tcp_in.c` `tcp_input_delayed_close`: **always** fire
   `TCP_EVENT_ERR(..., ERR_CLSD)` — removed the `TF_RXCLOSED` skip.
2. `old-src/core/tcp.c` slowtmr TIME_WAIT reap: save `errf`/`callback_arg`
   and fire `TCP_EVENT_ERR(..., ERR_ABRT)` after `tcp_free` (mirrors the
   active-list reap). No-op for pcbs whose `Drop` already cleared `errf`.

Both are safe: the Rust `tcp_err_cb` only marks its own context, never
touches the pcb.

## Follow-up checklist

Verification:
- [ ] **Zero new `PacketTunnel-*.ips`** (Settings → Privacy & Security →
  Analytics → Analytics Data) for ~3 days of heavy use. Was ~15/day.
  If one appears: pull it + `/tmp/meow-pt-full.log`-style capture; the
  diag build still dumps list walks + lifecycle ring + callers on any
  assert, so a residual silent-free path will name itself.

Upstream & restore (order matters):
- [ ] Extract the two fixes (and only those) from `lwip-diag` into a
  commit on a fork of `madeye/lwip`; PR upstream. The fork also contains
  DIAG-ONLY code (ring, cycle abort, `TCP_DEBUG_PCB_LISTS`,
  `meow_dump_evidence`, caller logging) that must NOT go upstream.
- [ ] `core/rust/meow-ios-ffi/Cargo.toml`: repoint `[patch.crates-io]`
  lwip to the upstream rev (currently `path = "/Users/gang/proj/lwip-diag"`
  — marked DO NOT COMMIT), restore `strip = "symbols"` (currently
  `false` for self-symbolicating .ips).
- [ ] Decide the fate of the diagnostics: keep `TCP_DEBUG_PCB_LISTS` +
  bounded sanity walk in dev builds as a tripwire, or drop entirely.
  Bounded `tcp_pcbs_sane` walk + assert→os_log routing are cheap and
  turn silent corruption into loud crashes; worth considering for dev.
- [ ] Working tree cleanup: `meow-ios.xcodeproj/project.pbxproj` has
  local `DEVELOPMENT_TEAM` + xcodegen drift — do NOT commit; regenerate
  via `scripts/generate-xcodeproj.sh`. `MeowCore/include/meow_core.h`
  comment tweaks are separately committable if wanted.
- [ ] Consider upstreaming to `ssrlive/lwip` (the original upstream per
  the Cargo.toml comment) if madeye's fork accepts the patch first.

Not action items (settled):
- **Watchdog stays.** Reviewed 2026-07-24: lock-free heartbeat, ingress
  gating, non-blocking ingest (can't be taken hostage), bounded teardown
  → deterministic `cancelTunnelWithError:` escalation. Clean. The
  "ingress-thread blind spot" feared during the session was a
  measurement artifact (awk field bug), not a real gap.
- Deferred to the DNS doc: resolver UDP→TCP/DoH fallback; QUIC block
  ICMP-unreachable instead of silent drop.

## Evidence locations (ephemeral!)

`/tmp/meow-crashlogs/` (15 .ips), `/tmp/meow-pt-full.log` (full engine
log with the v3/v4 assert dumps). `/tmp` does not survive reboots — the
essential excerpts are inline above. The exported tunnel log lives at
`~/Documents/meow-tunnel-20260724-203303.log` (covers the DNS episode,
not the crashes).

---

## 2026-07-25 更新:修复上线后首次断言复现(1 次)

`idevicecrashreport` 共 17 个 PacketTunnel ips。按时间分清两类:

- **07-24 00:43 / 00:59 / 01:48 三次**:修复上线**之前**(修复+ICMP
  构建 07-24 23:01 装机),同签名,属旧问题的最后记录。
- **07-25 07:12:50 一次**:修复上线**之后**的首次复现,PID 9282
  (该进程 01:16 启动,即运行的是修复版)。SIGABRT,签名相同:
  tcp_pcbs_sane <- tcp_input <- ip4_input <- NetStackImpl::poll_flush。
  5.5 秒后系统自动重启为 PID 9890,用户无感。

07-25 崩溃前最后 15 条 ring 转换日志分析:

- 所有 `st=0`(CLOSED)转换的 caller 都是 `tcp_input_delayed_close`
  (tcp_in.c:629)——合法移除路径(tcp_pcb_remove + tcp_free)。
- 违规 pcb 的 CLOSED 化**没有经过任何已埋点**——静默路径仍在,
  修复堵掉了其中一部分(频率:修复前每天多次 → 修复后约 8 小时 1 次)。
- 崩溃发生在 CN App 正常浏览期间,无 dial-deadline 风暴、与 ICMP
  reject 无明显相关。
- 断言在每次 tcp_input 入口触发,腐化可能发生在任意两次输入之间
  (定时器/callback/其他任务),而非当次输入内。

**下一步诊断升级:** tcp_pcbs_sane 失败时不裸 abort,先打印:
(1) 具体触发的断言;(2) 违规 pcb 的地址/state/ports;
(3) 从 meow_pcb_ring 回溯该 pcb 的全部历史转换。下一次崩溃的
syslog 即可直接指认静默路径。实施位置:
lwip-diag/src/core/tcp.c tcp_pcbs_sane()。

### 07-25 崩溃的机制实锤(证据链)

崩溃断言:`tw pcb->state == TIME-WAIT`(tcp.c:2749)。evidence dump 显示:

- tw 链表尾部 [18]→[19]→[20]→[21] 是**三个刚注册的 SYN_RCVD pcb**
  (0x105c83fd0/0x105c881d0/0x105c839a0),按 TCP_REG 的逆序串在 tw 尾部;
- ring 中 0x105c83fd0 的历史:VA(CLOSING 摘除)→ GT(TIME_WAIT 注册)
  → GA(新连接 SYN_RCVD 注册),**中间没有任何 V/f 记录**;
- 该 pcb 进 TW 距崩溃不足 2×MSL,**未过期**,排除 slowtmr 收割;
- tcp_free 有 'f' 埋点、TCP_RMV 有 'V' 埋点,两者都缺失
  → 该块从未经过正常释放,却被 tcp_alloc 发出去了。

**结论:这是 free-list 层面的 double-free**——某个更早的静默二次释放
(发生在 ring 窗口之前)把仍链在 tw 上的块推回了 pool;tcp_alloc 把它
发给新连接,造成 active↔tw 列表焊接。与问题 A 文档预判的机制一致,
但触发路径不是已修的两条。

### 诊断升级(2026-07-25,xcframework 已重编,待装机复现)

在第二次 free 的**当场**抓获,而不是等下游断言:

- `struct tcp_pcb` 尾部新增 `u32_t meow_magic`;
- `tcp_alloc`:memset 前检查 `magic == ALLOC` → `meow_tcp_magic_abort`
  (pool 发出了一个仍然活着的块);
- `tcp_free`:释放前检查 `magic != ALLOC` → 同上(第二次 free 现场,
  caller 进 ring + __crashreporter_info__);通过后盖章 `FREE`;
- slowtmr 两处手工 unlink(active/tw 收割)补记 ring 'V'(原来不走
  TCP_RMV,无记录)。
- 改动全部在 lwip-diag old-src(tcp.h / tcp.c),不影响正常路径行为。

下次崩溃 ips 的 asi/crashreporter 会直接给出 "PCB MAGIC violation in
tcp_free/tcp_alloc + pcb + caller",ring 里的 caller 可 atos 定位到
具体的静默释放路径。

### 2026-07-25 07:54:08 崩溃:magic 诊断当场抓获,第三条静默路径定位并修复

装机 40 分钟后复现,meow_magic 直接在凶案现场 abort:

- 签名:`meow_tcp_magic_abort <- tcp_free <- tcp_close_shutdown <-
  TcpStreamImpl::drop`(Rust Drop 对已释放的 pcb 二次释放)。
- Drop 有 `ctx.errored` 守卫(lwip 释放时发 err 回调就会置位,Drop
  不再碰 pcb)——它仍然调了 `tcp_close`,说明第一次释放**没有通知
  Rust**。
- 逐一排查所有 free 路径的通知覆盖:delayed_close(ERR_CLSD,已修)、
  slowtmr active(ERR_ABRT,stock)、slowtmr TW(ERR_ABRT,已修)、
  tcp_abandon 非 TW(ERR_ABRT,stock)——唯一缺口:
  **`tcp_abandon` 的 TIME_WAIT 分支(stock lwip 就不发任何回调)**,
  由 `tcp_kill_timewait`(tcp_alloc 在 memp 耗尽时杀最老 TW)触发。
  SYN 突发 → pool 压力 → kill_timewait → 半关闭 Rust 流(TX 已
  shutdown、对端 FIN 后 pcb 停在 TIME_WAIT、Drop 未跑)的 pcb 被静默
  释放 → Drop 二次 free。与 07:12:50 的"TW pcb 未过期即被重用"
  完全自洽。
- **修复**:`tcp_abandon` TW 分支在 remove+free 后补发
  `TCP_EVENT_ERR(ERR_ABRT)`(与 slowtmr TW 修复同模式;Drop 会先清
  errf,正常路径为 no-op)。
- 旁证:07:54 崩溃时 ring 里应有 kill 路径的 V/f 记录,但当时未挂
  syslog 捕获,未能取回;不影响结论(代码路径审计已穷举)。

至此已修三条静默路径:delayed_close(ERR_CLSD)、slowtmr TW 收割、
tcp_abandon TW 分支。lwip 内所有释放 pcb 的代码路径现已全部覆盖
err 通知。若再崩溃,大概率是第四条未知路径,magic 会继续当场抓获。
