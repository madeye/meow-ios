//! RSS-pressure stress tests for the FFI.
//!
//! These tests don't replace the on-device profile against the 50 MiB jetsam
//! cap — they're a fast, hermetic guard rail that surfaces obvious regressions
//! in the FFI's bookkeeping (channels, registries, runtime overhead) before
//! they ever ship to a device. The on-device verification still happens
//! through `macos-utun-harness`'s `stress` subcommand, which exercises real
//! flows through real proxies.
//!
//! What runs here:
//!
//!   * `tun_start_stop_cycles_do_not_leak` — repeatedly starts and stops the
//!     tun2socks driver. The runtime, channels, registries, and
//!     stack/listener tasks all get torn down between cycles. RSS after the
//!     cooldown must not exceed the baseline by more than a small budget.
//!
//!   * `sustained_ingest_burst_drops_under_load` — pushes a large burst of
//!     synthesized IP packets through `meow_tun_ingest` while tun2socks is
//!     running. Checks that the ingress mpsc back-pressures (drops on full
//!     rather than allocating unboundedly) and that post-cooldown RSS is
//!     close to the pre-burst baseline.
//!
//! The tests must run serially because the FFI owns global state. Cargo
//! ships them as a single integration binary, which already serializes
//! `#[test]` functions within the file unless `--test-threads=N>1`. Each test
//! also calls `meow_tun_stop` in its own teardown so a panic in one doesn't
//! leave the next test fighting over the same `TUN2SOCKS_RUNNING` flag.

#![cfg(target_vendor = "apple")]

use meow_ios_ffi::{meow_core_init, meow_tun_ingest, meow_tun_start, meow_tun_stop, rss};
use std::os::raw::c_void;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Duration;

static EGRESS_BYTES: AtomicU64 = AtomicU64::new(0);
static EGRESS_PACKETS: AtomicU64 = AtomicU64::new(0);

unsafe extern "C" fn count_egress(_ctx: *mut c_void, _data: *const u8, len: usize) {
    EGRESS_BYTES.fetch_add(len as u64, Ordering::Relaxed);
    EGRESS_PACKETS.fetch_add(1, Ordering::Relaxed);
}

fn ensure_init() {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| meow_core_init());
}

/// Hand-built minimal IPv4 + UDP packet bound for 172.19.0.2:53 (the
/// fake-IP pool's DNS server address). The intercept path in `tun2socks.rs`
/// matches on `dst_port == 53` regardless of dst_ip, so this is enough to
/// exercise the spawn-per-DNS-query branch without a real engine: the
/// spawned task short-circuits on `engine::tunnel() == None` and unwinds.
/// Source port is parameterised so each packet looks like a distinct flow.
fn synth_dns_packet(src_port: u16) -> Vec<u8> {
    let payload: &[u8] = &[
        // DNS header: ID 0xABCD, RD set, 1 question
        0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // qname "a.b" (1 'a' . 1 'b' . 0)
        0x01, b'a', 0x01, b'b', 0x00, // qtype A (1), qclass IN (1)
        0x00, 0x01, 0x00, 0x01,
    ];
    let udp_len: u16 = 8 + payload.len() as u16;
    let total_len: u16 = 20 + udp_len;

    let mut pkt = Vec::with_capacity(total_len as usize);
    // IPv4 header (20 bytes, no options)
    pkt.push(0x45);
    pkt.push(0x00);
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&[0x12, 0x34]); // identification
    pkt.extend_from_slice(&[0x40, 0x00]); // flags=DF, fragment offset=0
    pkt.push(64); // TTL
    pkt.push(17); // protocol = UDP
    pkt.extend_from_slice(&[0x00, 0x00]); // header checksum (not validated by the intercept)
    pkt.extend_from_slice(&[10, 0, 0, 7]); // src 10.0.0.7
    pkt.extend_from_slice(&[172, 19, 0, 2]); // dst 172.19.0.2
                                             // UDP header
    pkt.extend_from_slice(&src_port.to_be_bytes());
    pkt.extend_from_slice(&53u16.to_be_bytes());
    pkt.extend_from_slice(&udp_len.to_be_bytes());
    pkt.extend_from_slice(&[0x00, 0x00]); // UDP checksum 0 (legal on IPv4)
    pkt.extend_from_slice(payload);
    pkt
}

/// Settle the runtime so async cleanup catches up before sampling RSS.
/// Drops jitter from the post-burst measurement: if we sample immediately
/// after the last `meow_tun_ingest` call, the spawned tasks are still in
/// flight and their per-task allocations look like a leak.
fn cooldown(d: Duration) {
    std::thread::sleep(d);
}

fn rss_mib() -> f64 {
    rss::resident_mib().expect("RSS sampler must succeed on Apple targets")
}

#[test]
fn tun_start_stop_cycles_do_not_leak() {
    ensure_init();

    // Warm-up: the very first start spins up the tokio runtime, allocates
    // the smoltcp stack, etc. That cost is paid once per process lifetime
    // and is not what this test is policing — fold it into the baseline.
    unsafe {
        let rc = meow_tun_start(std::ptr::null_mut(), count_egress);
        assert_eq!(rc, 0, "warm-up start succeeds");
        meow_tun_stop();
    }
    cooldown(Duration::from_millis(200));
    let baseline = rss_mib();

    const CYCLES: usize = 50;
    for i in 0..CYCLES {
        unsafe {
            let rc = meow_tun_start(std::ptr::null_mut(), count_egress);
            assert_eq!(rc, 0, "cycle {} start", i);
            meow_tun_stop();
        }
    }
    cooldown(Duration::from_millis(500));
    let after = rss_mib();
    let delta = after - baseline;
    eprintln!(
        "tun_start_stop_cycles: baseline={:.2} MiB, after {} cycles={:.2} MiB, delta={:.2} MiB",
        baseline, CYCLES, after, delta
    );
    // Budget: 8 MiB. Pre-fix bursty-on-flow growth would cross this
    // immediately; nominal post-fix growth across 50 cycles should be
    // under 1 MiB once the stack/runtime allocations have stabilised.
    assert!(
        delta < 8.0,
        "RSS grew {:.2} MiB across {} start/stop cycles (budget 8.0 MiB)",
        delta,
        CYCLES
    );
}

#[test]
fn sustained_ingest_burst_drops_under_load() {
    ensure_init();
    EGRESS_BYTES.store(0, Ordering::Relaxed);
    EGRESS_PACKETS.store(0, Ordering::Relaxed);

    unsafe {
        let rc = meow_tun_start(std::ptr::null_mut(), count_egress);
        assert_eq!(rc, 0, "tun2socks start");
    }
    // Let the runtime warm.
    cooldown(Duration::from_millis(100));
    let baseline = rss_mib();

    // 10k synthetic DNS packets across distinct src ports. The ingress
    // mpsc capacity is 256 — sustained sends well above that surface
    // either back-pressure (drops, fine) or unbounded growth (the bug).
    const PACKETS: u32 = 10_000;
    let mut peak = baseline;
    for i in 0..PACKETS {
        let port = 1024 + (i as u16 % 60_000);
        let pkt = synth_dns_packet(port);
        unsafe { meow_tun_ingest(pkt.as_ptr(), pkt.len()) };
        if i % 1000 == 0 {
            let now = rss_mib();
            if now > peak {
                peak = now;
            }
        }
    }
    cooldown(Duration::from_secs(4)); // > DNS_PASSTHROUGH_TIMEOUT (3s)
    let after = rss_mib();
    meow_tun_stop();
    cooldown(Duration::from_millis(500));
    let post_stop = rss_mib();

    eprintln!(
        "sustained_ingest_burst: baseline={:.2} MiB, peak~={:.2} MiB, after_cooldown={:.2} MiB, post_stop={:.2} MiB",
        baseline, peak, after, post_stop
    );

    // Two assertions, decreasing strictness:
    //   * peak under sustained load < 30 MiB above baseline. The on-device
    //     budget is 50 MiB total; if a 10k burst alone eats 30+ above
    //     baseline, on-device load will jetsam well before that.
    //   * post-cooldown < 8 MiB above baseline. The spawned passthrough
    //     tasks all unwind on `engine::tunnel() == None`; nothing should
    //     remain pinned past their unwind.
    let peak_delta = peak - baseline;
    let cool_delta = after - baseline;
    assert!(
        peak_delta < 30.0,
        "RSS peaked at +{:.2} MiB during burst (budget 30 MiB)",
        peak_delta
    );
    assert!(
        cool_delta < 8.0,
        "RSS held +{:.2} MiB above baseline 4s after burst (budget 8 MiB)",
        cool_delta
    );
}
