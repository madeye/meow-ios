//! macOS `utun` device open / read / write.
//!
//! macOS exposes utun via a kernel control socket (`PF_SYSTEM` +
//! `SYSPROTO_CONTROL`). We resolve the kernel control unit for
//! `com.apple.net.utun_control` with `CTLIOCGINFO`, then `connect()` a
//! `sockaddr_ctl` against it. The `sc_unit` field picks a specific
//! `utunN` (0 = "first available"); the actual unit chosen is read back
//! via `getsockopt(UTUN_OPT_IFNAME)`.
//!
//! Wire format: every packet on macOS utun is prefixed with a 4-byte
//! address-family word (BE u32 = `AF_INET` / `AF_INET6`). We strip it on
//! read and prepend it on write so the upper layer (`meow_tun_ingest` /
//! the egress callback) sees plain IP packets exactly as the iOS
//! `NEPacketTunnelFlow` path does.

use anyhow::{anyhow, Context, Result};
use libc::{
    c_void, close, connect, getsockopt, ioctl, sockaddr, sockaddr_ctl, socket, socklen_t,
    AF_SYSTEM, AF_SYS_CONTROL, PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL,
};
use std::ffi::CStr;
use std::mem::{size_of, MaybeUninit};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

const UTUN_CONTROL_NAME: &[u8] = b"com.apple.net.utun_control\0";

// Values from `<sys/sys_domain.h>` / `<net/if_utun.h>` not always present in
// libc's published constants. Stable since Darwin 10.7.
const CTLIOCGINFO: libc::c_ulong = 0xc064_4e03; // _IOWR('N', 3, struct ctl_info)
const UTUN_OPT_IFNAME: libc::c_int = 2;
const MAX_IFNAME: usize = 16;

#[repr(C)]
struct CtlInfo {
    ctl_id: u32,
    ctl_name: [u8; 96],
}

/// Opened utun handle. Drop closes the fd, which the kernel translates into
/// removing the corresponding `utunN` interface.
pub(crate) struct Utun {
    fd: OwnedFd,
    name: String,
}

impl Utun {
    /// Open a new utun interface. `unit_hint` of 0 means "first free unit";
    /// any other value asks the kernel for that specific `utunN` and fails
    /// with EBUSY if it's already taken.
    pub(crate) fn open(unit_hint: u32) -> Result<Self> {
        // SAFETY: socket() takes scalar args and returns -1 on error.
        let raw = unsafe { socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL) };
        if raw < 0 {
            return Err(std::io::Error::last_os_error()).context("socket(PF_SYSTEM)");
        }
        // SAFETY: the fd is valid; wrap immediately so we close on early return.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };

        let mut info = CtlInfo {
            ctl_id: 0,
            ctl_name: [0u8; 96],
        };
        info.ctl_name[..UTUN_CONTROL_NAME.len()].copy_from_slice(UTUN_CONTROL_NAME);
        // SAFETY: CTLIOCGINFO fills `info` in-place.
        if unsafe { ioctl(fd.as_raw_fd(), CTLIOCGINFO, &mut info as *mut _) } < 0 {
            return Err(std::io::Error::last_os_error()).context("ioctl(CTLIOCGINFO)");
        }

        let addr = sockaddr_ctl {
            sc_len: size_of::<sockaddr_ctl>() as u8,
            sc_family: AF_SYSTEM as u8,
            ss_sysaddr: AF_SYS_CONTROL as u16,
            sc_id: info.ctl_id,
            sc_unit: unit_hint,
            sc_reserved: [0; 5],
        };
        // SAFETY: addr is a valid sockaddr_ctl on the stack; cast to sockaddr is
        // the canonical BSD pattern.
        let rc = unsafe {
            connect(
                fd.as_raw_fd(),
                &addr as *const sockaddr_ctl as *const sockaddr,
                size_of::<sockaddr_ctl>() as socklen_t,
            )
        };
        if rc < 0 {
            return Err(std::io::Error::last_os_error()).context("connect(utun_control)");
        }

        let name = Self::read_ifname(fd.as_raw_fd())?;
        Ok(Utun { fd, name })
    }

    fn read_ifname(fd: RawFd) -> Result<String> {
        let mut buf = MaybeUninit::<[u8; MAX_IFNAME]>::zeroed();
        let mut len = MAX_IFNAME as socklen_t;
        // SAFETY: getsockopt fills `buf` up to `len`.
        let rc = unsafe {
            getsockopt(
                fd,
                SYSPROTO_CONTROL,
                UTUN_OPT_IFNAME,
                buf.as_mut_ptr() as *mut c_void,
                &mut len,
            )
        };
        if rc < 0 {
            return Err(std::io::Error::last_os_error()).context("getsockopt(UTUN_OPT_IFNAME)");
        }
        // SAFETY: getsockopt populated `len` bytes (NUL-terminated).
        let raw = unsafe { buf.assume_init() };
        let name = CStr::from_bytes_until_nul(&raw[..len as usize])
            .map_err(|e| anyhow!("utun ifname missing NUL: {}", e))?
            .to_str()
            .context("utun ifname is not utf-8")?;
        Ok(name.to_owned())
    }

    pub(crate) fn name(&self) -> &str {
        &self.name
    }

    pub(crate) fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    // Read / write helpers live inline in `main.rs` because the egress
    // callback (extern "C" fn) shares the fd via a static `AtomicI32` and
    // the ingest loop uses raw `libc::read` to interplay with shutdown
    // (closing the fd unblocks `read` with EBADF). Keeping them off the
    // `Utun` impl avoids creating a second drop owner for the fd.
}

impl Drop for Utun {
    fn drop(&mut self) {
        // OwnedFd handles close; this Drop exists for the doc-side note that
        // closing removes the interface. Nothing to do here.
        let _ = self.fd.as_raw_fd();
    }
}

/// Explicit close helper used at shutdown so the interface goes away
/// promptly instead of racing the process exit.
pub(crate) fn force_close(fd: RawFd) {
    // SAFETY: caller asserts fd is the utun fd and no other thread is using it.
    unsafe {
        close(fd);
    }
}
