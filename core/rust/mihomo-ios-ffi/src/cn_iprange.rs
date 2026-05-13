//! CN IP-range membership check used by the fake-IP DNS handler to bypass
//! the fake-IP pool for hostnames that resolve into mainland-CN address
//! space — in that case we return the upstream-resolved real IP directly so
//! the client connects via the engine's DIRECT outbound rather than through
//! a SOCKS-rerouted fake-IP flow.
//!
//! Data sources are produced offline by `scripts/build-cn-iprange.py` from
//! APNIC's delegated stats and shipped as bundle assets:
//!
//!   `<app-bundle>/cn-ipv4.bin`  →  `<home>/mihomo/cn-ipv4.bin`
//!   `<app-bundle>/cn-ipv6.bin`  →  `<home>/mihomo/cn-ipv6.bin`
//!
//! Wire format (little-endian throughout, mirrors the python writer):
//!
//! ```text
//!   offset  size    field
//!        0  4       magic     = b"CNIP"
//!        4  1       version   = 1
//!        5  1       af        = 4  (cn-ipv4.bin)  | 6  (cn-ipv6.bin)
//!        6  2       reserved  = 0
//!        8  4       count
//!       12  N*K     intervals K = 8 (v4: 2x u32) | 32 (v6: 2x u128 as 2x u64)
//! ```
//!
//! Intervals are sorted ascending by `start` and coalesced (adjacent /
//! overlapping spans pre-merged), so membership reduces to one binary search
//! per check via `partition_point`.
//!
//! Missing or malformed files are non-fatal: the table stays empty, every
//! `contains_*` returns `false`, and `fake_ip_dns::handle_query` falls
//! through to its existing fake-IP allocation path. This is the right
//! default for an asset that may not have been seeded yet (first launch race
//! with `AssetSeeder`) — failing closed would silently disable the fake-IP
//! mode itself.

use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::Path;
use std::sync::OnceLock;
use tracing::{debug, warn};

const MAGIC: &[u8; 4] = b"CNIP";
const VERSION: u8 = 1;

/// Sorted, coalesced, inclusive `[start, end]` intervals over the IPv4 u32
/// space.
static V4: OnceLock<Vec<(u32, u32)>> = OnceLock::new();

/// Sorted, coalesced, inclusive `[start, end]` intervals over the IPv6 u128
/// space.
static V6: OnceLock<Vec<(u128, u128)>> = OnceLock::new();

/// Best-effort load of both files. Errors are logged but never propagated —
/// the engine boots regardless. Callers (engine::start) invoke this once
/// per process; second-call no-ops because of `OnceLock::set`.
pub(crate) fn load(home_dir: &Path) {
    let v4_path = home_dir.join("mihomo").join("cn-ipv4.bin");
    match load_v4(&v4_path) {
        Ok(intervals) => {
            debug!(
                "cn_iprange: loaded {} v4 intervals from {}",
                intervals.len(),
                v4_path.display()
            );
            let _ = V4.set(intervals);
        }
        Err(e) => warn!("cn_iprange: v4 load skipped ({}): {}", v4_path.display(), e),
    }

    let v6_path = home_dir.join("mihomo").join("cn-ipv6.bin");
    match load_v6(&v6_path) {
        Ok(intervals) => {
            debug!(
                "cn_iprange: loaded {} v6 intervals from {}",
                intervals.len(),
                v6_path.display()
            );
            let _ = V6.set(intervals);
        }
        Err(e) => warn!("cn_iprange: v6 load skipped ({}): {}", v6_path.display(), e),
    }
}

/// `true` iff `ip` falls inside any CN v4 interval. Always `false` until the
/// table is loaded (first call to [`load`]).
pub(crate) fn contains_v4(ip: Ipv4Addr) -> bool {
    let Some(intervals) = V4.get() else {
        return false;
    };
    let key = u32::from(ip);
    // partition_point returns the first index whose start > key; the candidate
    // interval is the one immediately before it.
    let idx = intervals.partition_point(|(start, _)| *start <= key);
    if idx == 0 {
        return false;
    }
    let (_, end) = intervals[idx - 1];
    key <= end
}

/// `true` iff `ip` falls inside any CN v6 interval.
pub(crate) fn contains_v6(ip: Ipv6Addr) -> bool {
    let Some(intervals) = V6.get() else {
        return false;
    };
    let key = u128::from(ip);
    let idx = intervals.partition_point(|(start, _)| *start <= key);
    if idx == 0 {
        return false;
    }
    let (_, end) = intervals[idx - 1];
    key <= end
}

fn load_v4(path: &Path) -> std::io::Result<Vec<(u32, u32)>> {
    let bytes = std::fs::read(path)?;
    let (count, body) = parse_header(&bytes, 4)?;
    if body.len() != count.saturating_mul(8) {
        return Err(invalid("body length mismatch (v4)"));
    }
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let off = i * 8;
        let start = u32::from_le_bytes(body[off..off + 4].try_into().unwrap());
        let end = u32::from_le_bytes(body[off + 4..off + 8].try_into().unwrap());
        if start > end {
            return Err(invalid("v4 interval start > end"));
        }
        if let Some(prev_end) = out.last().map(|(_, e): &(u32, u32)| *e) {
            // Generator coalesces + sorts; reject anything that violates that
            // invariant so `partition_point` membership is sound.
            if start <= prev_end {
                return Err(invalid("v4 intervals not strictly increasing / coalesced"));
            }
        }
        out.push((start, end));
    }
    Ok(out)
}

fn load_v6(path: &Path) -> std::io::Result<Vec<(u128, u128)>> {
    let bytes = std::fs::read(path)?;
    let (count, body) = parse_header(&bytes, 6)?;
    if body.len() != count.saturating_mul(32) {
        return Err(invalid("body length mismatch (v6)"));
    }
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let off = i * 32;
        let start = read_u128_le(&body[off..off + 16]);
        let end = read_u128_le(&body[off + 16..off + 32]);
        if start > end {
            return Err(invalid("v6 interval start > end"));
        }
        if let Some(prev_end) = out.last().map(|(_, e): &(u128, u128)| *e) {
            if start <= prev_end {
                return Err(invalid("v6 intervals not strictly increasing / coalesced"));
            }
        }
        out.push((start, end));
    }
    Ok(out)
}

/// Validate the 12-byte header and return `(count, body)`.
fn parse_header(bytes: &[u8], expected_af: u8) -> std::io::Result<(usize, &[u8])> {
    if bytes.len() < 12 {
        return Err(invalid("file shorter than 12-byte header"));
    }
    if &bytes[0..4] != MAGIC {
        return Err(invalid("bad magic"));
    }
    if bytes[4] != VERSION {
        return Err(invalid("unsupported version"));
    }
    if bytes[5] != expected_af {
        return Err(invalid("address-family mismatch"));
    }
    // bytes[6..8] reserved; intentionally not validated against 0 to leave
    // room for future flags without bumping VERSION.
    let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
    Ok((count, &bytes[12..]))
}

fn read_u128_le(b: &[u8]) -> u128 {
    // Wire format stores u128 as two LE u64 halves: lo first, then hi.
    let lo = u64::from_le_bytes(b[0..8].try_into().unwrap()) as u128;
    let hi = u64::from_le_bytes(b[8..16].try_into().unwrap()) as u128;
    (hi << 64) | lo
}

fn invalid(msg: &'static str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, msg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_v4_blob(intervals: &[(u32, u32)]) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(MAGIC);
        buf.push(VERSION);
        buf.push(4);
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&(intervals.len() as u32).to_le_bytes());
        for (s, e) in intervals {
            buf.extend_from_slice(&s.to_le_bytes());
            buf.extend_from_slice(&e.to_le_bytes());
        }
        buf
    }

    fn write_v6_blob(intervals: &[(u128, u128)]) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(MAGIC);
        buf.push(VERSION);
        buf.push(6);
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&(intervals.len() as u32).to_le_bytes());
        for (s, e) in intervals {
            buf.extend_from_slice(&((s & u64::MAX as u128) as u64).to_le_bytes());
            buf.extend_from_slice(&((s >> 64) as u64).to_le_bytes());
            buf.extend_from_slice(&((e & u64::MAX as u128) as u64).to_le_bytes());
            buf.extend_from_slice(&((e >> 64) as u64).to_le_bytes());
        }
        buf
    }

    fn write_temp(prefix: &str, data: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "{}-{}-{}.bin",
            prefix,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(data).unwrap();
        path
    }

    fn ip4(a: u8, b: u8, c: u8, d: u8) -> u32 {
        u32::from(Ipv4Addr::new(a, b, c, d))
    }

    #[test]
    fn parse_v4_round_trip() {
        let ivals = vec![
            (ip4(1, 0, 0, 0), ip4(1, 0, 0, 255)),
            (ip4(10, 0, 0, 0), ip4(10, 255, 255, 255)),
        ];
        let blob = write_v4_blob(&ivals);
        let path = write_temp("cnip-v4-rt", &blob);
        let parsed = load_v4(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(parsed, ivals);
    }

    #[test]
    fn parse_v6_round_trip() {
        let ivals = vec![
            (1u128, 100u128),
            ((1u128 << 64) | 5, (1u128 << 64) | 50),
            (u128::MAX - 10, u128::MAX),
        ];
        let blob = write_v6_blob(&ivals);
        let path = write_temp("cnip-v6-rt", &blob);
        let parsed = load_v6(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(parsed, ivals);
    }

    #[test]
    fn rejects_bad_magic() {
        let mut blob = write_v4_blob(&[]);
        blob[0] = b'X';
        let path = write_temp("cnip-magic", &blob);
        let err = load_v4(&path).unwrap_err();
        std::fs::remove_file(&path).ok();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn rejects_af_mismatch() {
        let blob = write_v4_blob(&[(1, 2)]);
        let path = write_temp("cnip-af", &blob);
        // Try to load as v6 — must fail.
        let err = load_v6(&path).unwrap_err();
        std::fs::remove_file(&path).ok();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn rejects_unsorted_intervals() {
        let blob = write_v4_blob(&[(100, 200), (50, 60)]);
        let path = write_temp("cnip-sorted", &blob);
        let err = load_v4(&path).unwrap_err();
        std::fs::remove_file(&path).ok();
        assert!(err.to_string().contains("increasing"));
    }

    #[test]
    fn rejects_uncoalesced_intervals() {
        // Adjacent or overlapping ranges should have been coalesced.
        let blob = write_v4_blob(&[(0, 100), (50, 200)]);
        let path = write_temp("cnip-coal", &blob);
        assert!(load_v4(&path).is_err());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn binary_search_v4() {
        // Use the static V4 indirectly via a local helper that mimics it.
        let intervals: Vec<(u32, u32)> = vec![
            (ip4(1, 0, 0, 0), ip4(1, 0, 0, 255)), // 1.0.0.0/24
            (ip4(36, 0, 0, 0), ip4(36, 255, 255, 255)),
            (ip4(180, 0, 0, 0), ip4(180, 0, 1, 255)),
        ];
        // Replicates contains_v4 logic locally so the test is independent of
        // the OnceLock publication state (which is test-order-dependent).
        let contains = |ip: Ipv4Addr| {
            let key = u32::from(ip);
            let idx = intervals.partition_point(|(s, _)| *s <= key);
            if idx == 0 {
                return false;
            }
            key <= intervals[idx - 1].1
        };
        assert!(contains(Ipv4Addr::new(1, 0, 0, 0)));
        assert!(contains(Ipv4Addr::new(1, 0, 0, 255)));
        assert!(!contains(Ipv4Addr::new(1, 0, 1, 0)));
        assert!(contains(Ipv4Addr::new(36, 17, 200, 1)));
        assert!(!contains(Ipv4Addr::new(8, 8, 8, 8)));
        assert!(!contains(Ipv4Addr::new(0, 0, 0, 0)));
        assert!(contains(Ipv4Addr::new(180, 0, 1, 255)));
        assert!(!contains(Ipv4Addr::new(180, 0, 2, 0)));
    }

    #[test]
    fn binary_search_v6() {
        let intervals: Vec<(u128, u128)> = vec![
            // 2400:3200::/32 -- one of CNNIC's allocations.
            (
                0x2400_3200_0000_0000_0000_0000_0000_0000,
                0x2400_3200_ffff_ffff_ffff_ffff_ffff_ffff,
            ),
        ];
        let contains = |ip: Ipv6Addr| {
            let key = u128::from(ip);
            let idx = intervals.partition_point(|(s, _)| *s <= key);
            if idx == 0 {
                return false;
            }
            key <= intervals[idx - 1].1
        };
        assert!(contains("2400:3200::1".parse().unwrap()));
        assert!(contains("2400:3200:ffff::abcd".parse().unwrap()));
        assert!(!contains("2400:3201::1".parse().unwrap()));
        assert!(!contains("2001:db8::1".parse().unwrap()));
    }

    #[test]
    fn unloaded_table_returns_false() {
        // Default state of contains_v4 / contains_v6 when nothing was loaded:
        // safe-by-default false (caller falls through to fake-IP allocation).
        // We can't assume the global OnceLock state, but we can assert the
        // function does not panic for an arbitrary address.
        let _ = contains_v4(Ipv4Addr::new(1, 2, 3, 4));
        let _ = contains_v6("::1".parse().unwrap());
    }
}
