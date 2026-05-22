//! Resident-memory sampling for the FFI.
//!
//! The PacketTunnel extension is killed by jetsam when its physical-footprint
//! reading crosses ~50 MB on a real device. The same `resident_size` field
//! that jetsam watches is available to userland through `mach_task_self` +
//! `task_info(TASK_BASIC_INFO)`, and on macOS the same call works for the
//! `macos-utun-harness` and `cargo test` binaries — so this module lets us
//! sample the exact number the OS would penalise us for both on-device and
//! on the dev box.
//!
//! Returns `None` on platforms where the mach call isn't available
//! (linux / windows CI runners), so callers can degrade to "skip the
//! assertion" rather than fail.

#[cfg(target_vendor = "apple")]
pub fn resident_bytes() -> Option<u64> {
    // mach_task_basic_info layout — see <mach/task_info.h>. Hard-coded so
    // we don't need to pull in the `mach2` crate just to read one field.
    #[repr(C)]
    #[derive(Default)]
    struct MachTaskBasicInfo {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: [u32; 2],
        system_time: [u32; 2],
        policy: i32,
        suspend_count: i32,
    }

    const MACH_TASK_BASIC_INFO: i32 = 20;
    // sizeof(MachTaskBasicInfo) / sizeof(u32). The flavor count is in
    // natural_t units, which is u32 on both arm64 and x86_64 Apple targets.
    const COUNT: u32 =
        (std::mem::size_of::<MachTaskBasicInfo>() / std::mem::size_of::<u32>()) as u32;

    extern "C" {
        fn mach_task_self() -> u32;
        fn task_info(
            target_task: u32,
            flavor: i32,
            task_info_out: *mut MachTaskBasicInfo,
            task_info_out_count: *mut u32,
        ) -> i32;
    }

    let mut info = MachTaskBasicInfo::default();
    let mut count = COUNT;
    // SAFETY: `task_info` writes at most `count * sizeof(u32)` bytes into
    // `info`, which is sized to hold exactly `COUNT` u32 words. The target
    // task self handle is always valid.
    let rc = unsafe {
        task_info(
            mach_task_self(),
            MACH_TASK_BASIC_INFO,
            &mut info,
            &mut count,
        )
    };
    if rc == 0 {
        Some(info.resident_size)
    } else {
        None
    }
}

#[cfg(not(target_vendor = "apple"))]
pub fn resident_bytes() -> Option<u64> {
    None
}

/// Convenience: `resident_bytes` rounded to MiB. `None` propagates from the
/// underlying sampler.
pub fn resident_mib() -> Option<f64> {
    resident_bytes().map(|b| b as f64 / (1024.0 * 1024.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_vendor = "apple")]
    fn resident_bytes_is_nonzero_on_apple() {
        let rss = resident_bytes().expect("mach call succeeds on Apple targets");
        assert!(rss > 0, "task RSS must be > 0 in a running test process");
        assert!(
            rss < 16 * 1024 * 1024 * 1024,
            "task RSS sanity (< 16 GiB), got {} bytes",
            rss
        );
    }

    #[test]
    fn resident_mib_matches_resident_bytes() {
        match (resident_bytes(), resident_mib()) {
            (Some(b), Some(m)) => {
                // `resident_bytes()` and `resident_mib()` each fire an
                // independent `task_info` mach call, so the two samples can
                // disagree by however much the resident set moved between
                // them. Under `cargo test`'s default parallelism, sibling
                // tests allocate concurrently and pages come/go in the
                // window. Validate the conversion shape (≤ a few MiB drift)
                // rather than bit-exact equality, which only held when the
                // process happened to be quiescent.
                let expected = b as f64 / (1024.0 * 1024.0);
                assert!(
                    (m - expected).abs() < 4.0,
                    "MiB conversion drift too large: bytes-derived={} mib-derived={}",
                    expected,
                    m,
                );
            }
            (None, None) => {} // non-Apple platform, both return None
            (b, m) => panic!("inconsistent sampler: bytes={:?} mib={:?}", b, m),
        }
    }
}
