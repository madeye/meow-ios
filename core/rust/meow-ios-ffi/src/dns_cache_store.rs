//! Disk persistence for the redir-host reverse DNS table.
//!
//! In redir-host (Mapping) mode the tunnel recovers hostnames for rule
//! matching from meow-dns's in-memory IP → host reverse table. That table
//! dies with the engine, but the connections that depend on it don't: after a
//! wake restart (or a jetsam kill + relaunch) apps keep dialing IPs they
//! resolved *before* the restart, and every such flow silently degrades to
//! IP-only rule matching. This module persists the reverse table to
//! `<home>/dns-reverse-cache.json` so `start()` can reload it.
//!
//! Layering: meow-dns owns the mechanism (`reverse_cache_snapshot` /
//! `restore_reverse_cache`, with `remaining: Duration` lifetimes); this module
//! owns the policy — file location, wall-clock anchoring (`Instant` doesn't
//! survive a process, so entries are persisted with absolute unix-epoch
//! expiries), save cadence, and corruption handling.
//!
//! Save triggers: a periodic task (60 s, skipped when the serialized table is
//! byte-identical to the last write — idle engines don't touch disk) plus a
//! final unconditional write in `engine::stop()`. The periodic task is what
//! covers jetsam kills, which never reach `stop()`.

use meow_dns::{Resolver, ReverseSnapshotEntry};
use serde::{Deserialize, Serialize};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tracing::{debug, info, warn};

const FILE_NAME: &str = "dns-reverse-cache.json";
const FORMAT_VERSION: u32 = 1;

/// Periodic save cadence. Coarse on purpose: the table is small (reverse cap
/// is 16 × 1024 entries ≈ tens of KB serialized in practice) but the NE
/// shares its jetsam budget with the data path — one bounded write per minute
/// of DNS activity is plenty to cover an unclean death.
pub const SAVE_INTERVAL: Duration = Duration::from_secs(60);

/// Sanity cap on entries accepted from disk. The in-memory table enforces its
/// own per-shard LRU caps on restore; this just refuses to buffer an absurd
/// (corrupt or crafted) file into a `Vec` first. Comfortably above the
/// engine's global reverse cap (16 shards × 1024).
const MAX_RESTORE_ENTRIES: usize = 65_536;

#[derive(Serialize, Deserialize)]
struct PersistedTable {
    version: u32,
    entries: Vec<PersistedEntry>,
}

#[derive(Serialize, Deserialize)]
struct PersistedEntry {
    ip: IpAddr,
    host: String,
    /// Absolute expiry, seconds since the unix epoch. Absolute (not
    /// remaining) so the value stays valid however long the file sits on
    /// disk — a phone that was off for an hour restores only what genuinely
    /// hasn't expired, and an idle engine can skip rewriting an unchanged
    /// table without the stored expiries drifting stale.
    expires_at: u64,
}

/// Serialized bytes of the last table this process wrote (FNV-1a hash), so
/// the periodic saver can skip disk entirely when nothing changed. 0 = no
/// write yet this process → first save always writes.
static LAST_WRITTEN_HASH: AtomicU64 = AtomicU64::new(0);

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn store_path() -> Option<PathBuf> {
    crate::HOME_DIR
        .lock()
        .clone()
        .map(|d| Path::new(&d).join(FILE_NAME))
}

/// Pure snapshot → persisted conversion, anchored at `now` (unix secs).
fn to_persisted(entries: Vec<ReverseSnapshotEntry>, now: u64) -> PersistedTable {
    PersistedTable {
        version: FORMAT_VERSION,
        entries: entries
            .into_iter()
            .map(|e| PersistedEntry {
                ip: e.ip,
                host: e.domain,
                expires_at: now.saturating_add(e.remaining.as_secs()),
            })
            .collect(),
    }
}

/// Pure persisted → snapshot conversion, anchored at `now` (unix secs).
/// Entries already expired on the wall clock are dropped here — the restart
/// gap is exactly the time the in-memory `Instant` clock couldn't see.
fn to_snapshot(table: PersistedTable, now: u64) -> Vec<ReverseSnapshotEntry> {
    if table.version != FORMAT_VERSION {
        return Vec::new();
    }
    table
        .entries
        .into_iter()
        .take(MAX_RESTORE_ENTRIES)
        .filter_map(|e| {
            let remaining = e.expires_at.checked_sub(now)?;
            if remaining == 0 {
                return None;
            }
            Some(ReverseSnapshotEntry {
                ip: e.ip,
                domain: e.host,
                remaining: Duration::from_secs(remaining),
            })
        })
        .collect()
}

/// Load the persisted table (if any) into `resolver`'s reverse cache. Call
/// once at engine start, before traffic. Corrupt or unreadable files are
/// logged and ignored — the table is a warm-start optimization, never worth
/// failing a start over.
pub fn restore(resolver: &Resolver) {
    let Some(path) = store_path() else {
        return;
    };
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            warn!("dns reverse cache: read {} failed: {e}", path.display());
            return;
        }
    };
    let table: PersistedTable = match serde_json::from_slice(&bytes) {
        Ok(t) => t,
        Err(e) => {
            warn!(
                "dns reverse cache: {} corrupt ({e}), discarding",
                path.display()
            );
            let _ = std::fs::remove_file(&path);
            return;
        }
    };
    let persisted = table.entries.len();
    let live = to_snapshot(table, now_epoch_secs());
    let restored = live.len();
    resolver.restore_reverse_cache(live);
    info!("dns reverse cache: restored {restored}/{persisted} entries");
}

/// Snapshot the reverse table and write it to disk (atomic tmp + rename).
/// `force` bypasses the unchanged-table skip — `stop()` uses it so the final
/// state always lands. Returns true when a write happened.
pub fn save(resolver: &Resolver, force: bool) -> bool {
    let Some(path) = store_path() else {
        return false;
    };
    let table = to_persisted(resolver.reverse_cache_snapshot(), now_epoch_secs());
    let bytes = match serde_json::to_vec(&table) {
        Ok(b) => b,
        Err(e) => {
            warn!("dns reverse cache: serialize failed: {e}");
            return false;
        }
    };
    // Snapshot order is IP-sorted (stable), and expiries are absolute, so an
    // idle table serializes byte-identically (modulo ±1 s rounding jitter on
    // the epoch anchor) and the periodic saver skips the disk entirely.
    let hash = fnv1a64(&bytes);
    if !force && LAST_WRITTEN_HASH.load(Ordering::Relaxed) == hash {
        debug!("dns reverse cache: unchanged, skipping save");
        return false;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("json.tmp");
    let written = std::fs::write(&tmp, &bytes)
        .and_then(|()| std::fs::rename(&tmp, &path))
        .map_err(|e| warn!("dns reverse cache: write {} failed: {e}", path.display()))
        .is_ok();
    if written {
        LAST_WRITTEN_HASH.store(hash, Ordering::Relaxed);
        debug!(
            "dns reverse cache: saved {} entries ({} bytes)",
            table.entries.len(),
            bytes.len()
        );
    }
    written
}

#[cfg(test)]
mod tests {
    use super::*;
    use meow_common::DnsMode;
    use std::net::Ipv4Addr;

    fn entry(ip: [u8; 4], host: &str, remaining: u64) -> ReverseSnapshotEntry {
        ReverseSnapshotEntry {
            ip: IpAddr::V4(Ipv4Addr::new(ip[0], ip[1], ip[2], ip[3])),
            domain: host.into(),
            remaining: Duration::from_secs(remaining),
        }
    }

    #[test]
    fn persisted_round_trip_preserves_live_entries() {
        let now = 1_800_000_000;
        let table = to_persisted(
            vec![
                entry([1, 2, 3, 4], "a.example", 600),
                entry([5, 6, 7, 8], "b.example", 30),
            ],
            now,
        );
        let bytes = serde_json::to_vec(&table).unwrap();
        let parsed: PersistedTable = serde_json::from_slice(&bytes).unwrap();
        let restored = to_snapshot(parsed, now);
        assert_eq!(restored.len(), 2);
        assert_eq!(restored[0].domain, "a.example");
        assert_eq!(restored[0].remaining, Duration::from_secs(600));
        assert_eq!(restored[1].remaining, Duration::from_secs(30));
    }

    #[test]
    fn restore_discounts_wall_clock_gap_and_drops_expired() {
        let saved_at = 1_800_000_000;
        let table = to_persisted(
            vec![
                entry([1, 1, 1, 1], "live.example", 600),
                entry([2, 2, 2, 2], "dead.example", 100),
            ],
            saved_at,
        );
        // Engine comes back 120 s later: the 100 s entry is gone, the 600 s
        // one has 480 s left.
        let restored = to_snapshot(table, saved_at + 120);
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].domain, "live.example");
        assert_eq!(restored[0].remaining, Duration::from_secs(480));
    }

    #[test]
    fn unknown_version_restores_nothing() {
        let table = PersistedTable {
            version: FORMAT_VERSION + 1,
            entries: vec![PersistedEntry {
                ip: IpAddr::V4(Ipv4Addr::LOCALHOST),
                host: "x.example".into(),
                expires_at: u64::MAX,
            }],
        };
        assert!(to_snapshot(table, 0).is_empty());
    }

    #[test]
    fn end_to_end_through_resolver() {
        // Full path minus disk: resolver A's table → persisted JSON →
        // resolver B answers reverse lookups after the "restart".
        let a = Resolver::new(vec![], vec![], DnsMode::Mapping, Default::default(), true);
        let ip = IpAddr::V4(Ipv4Addr::new(93, 184, 216, 34));
        a.preload_cache("persist.example", &[ip], Duration::from_secs(300));

        let now = now_epoch_secs();
        let table = to_persisted(a.reverse_cache_snapshot(), now);
        let bytes = serde_json::to_vec(&table).unwrap();

        let b = Resolver::new(vec![], vec![], DnsMode::Mapping, Default::default(), true);
        assert!(b.reverse_lookup(ip).is_none());
        let parsed: PersistedTable = serde_json::from_slice(&bytes).unwrap();
        b.restore_reverse_cache(to_snapshot(parsed, now));
        assert_eq!(b.reverse_lookup(ip).as_deref(), Some("persist.example"));
    }
}
