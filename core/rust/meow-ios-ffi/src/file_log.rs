//! Always-on debug ring written to a file in the App Group container.
//!
//! The engine's primary log sink is Apple unified logging (`oslog`, see
//! [`crate::logging`]). But the app process cannot read another process's
//! unified-log entries — `OSLogStore(scope: .currentProcessIdentifier)` is the
//! only scope iOS grants a non-entitled App Store app, and the engine + the
//! NetworkExtension host run in a *separate* process. So the in-app "export
//! logs" feature never sees the tunnel's own output.
//!
//! This module fixes that by teeing every tracing event (DEBUG and above,
//! regardless of the user-facing log-level setting) into
//! `<app-group-container>/logs/meow-tunnel.log`, a size-capped two-file ring
//! the app reads back on export. A file already flushed to disk survives a
//! runtime wedge and even an NE jetsam-kill, which the REST/IPC control path
//! does not (see `project_lwip_timer_livelock` / `project_udp_nat_dashmap_deadlock`)
//! — so the last lines before a freeze are exactly what ends up captured.
//!
//! Writes go through [`tracing_appender::non_blocking`]: a dedicated worker
//! thread owns the file, and the emitting (tokio) threads only push formatted
//! lines onto a bounded channel that drops on overflow. Logging therefore never
//! blocks the wedge-prone workers on disk I/O.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::OnceLock;

use tracing_appender::non_blocking::{NonBlocking, WorkerGuard};
use tracing_subscriber::fmt::MakeWriter;
// Brings the `with_filter` combinator on `fmt::Layer` into scope.
use tracing_subscriber::Layer as _;

/// Cap per file. Two files (active + one rotation) ⇒ ~8 MiB worst case on disk.
/// Big enough to hold many minutes of DEBUG churn — enough to span an idle
/// period and the wake that wedges — without unbounded growth.
const MAX_BYTES: u64 = 4 * 1024 * 1024;

/// The non-blocking worker guard. Must outlive the process for the worker
/// thread to keep draining; we install once and never tear down, so leaking it
/// into a `static` is correct (and avoids a Drop that would flush-and-join on
/// an unknown thread).
static GUARD: OnceLock<WorkerGuard> = OnceLock::new();

/// A plain file writer that rotates `meow-tunnel.log` → `meow-tunnel.log.1`
/// (overwriting the previous `.1`) once it crosses [`MAX_BYTES`], then starts a
/// fresh active file. All of this runs on the `non_blocking` worker thread, so
/// the rename + reopen never touch a tokio worker.
struct CappedFile {
    path: PathBuf,
    rotated: PathBuf,
    file: File,
    written: u64,
}

impl CappedFile {
    fn open(dir: &PathBuf) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let path = dir.join("meow-tunnel.log");
        let rotated = dir.join("meow-tunnel.log.1");
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(Self {
            path,
            rotated,
            file,
            written,
        })
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file.flush()?;
        // Overwrite the old rotation with the just-filled active file, then
        // start a clean active file. Best-effort: if the rename fails we keep
        // appending to the current (oversized) file rather than losing the sink.
        let _ = fs::rename(&self.path, &self.rotated);
        self.file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.path)?;
        self.written = 0;
        Ok(())
    }
}

impl Write for CappedFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.written.saturating_add(buf.len() as u64) > MAX_BYTES {
            self.rotate()?;
        }
        let n = self.file.write(buf)?;
        self.written += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

/// Wrapper so the `NonBlocking` handle satisfies `for<'a> MakeWriter<'a>`,
/// which `fmt::Layer::with_writer` requires.
#[derive(Clone)]
struct NbMakeWriter(NonBlocking);

impl<'a> MakeWriter<'a> for NbMakeWriter {
    type Writer = NonBlocking;
    fn make_writer(&'a self) -> Self::Writer {
        self.0.clone()
    }
}

/// Build the file-log layer if a home dir is set and the log file opens.
///
/// Returns `None` (and the registry simply omits it) when no App Group dir has
/// been configured yet or the file can't be created — logging must never be the
/// reason the engine fails to start.
pub fn layer<S>() -> Option<impl tracing_subscriber::Layer<S>>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    let home = crate::HOME_DIR.lock().clone()?;
    let dir = PathBuf::from(home).join("logs");
    let capped = match CappedFile::open(&dir) {
        Ok(f) => f,
        Err(e) => {
            // Surface via the oslog sink, which is already installed.
            log::error!("file_log: cannot open {:?}: {}", dir, e);
            return None;
        }
    };
    let (nb, guard) = tracing_appender::non_blocking(capped);
    // First install wins; a redundant call just drops its guard (and its file
    // handle), which is harmless because `install_tracing_subscriber` is a
    // `Once`.
    let _ = GUARD.set(guard);

    let layer = tracing_subscriber::fmt::layer()
        .with_ansi(false)
        .with_target(true)
        .with_level(true)
        .with_writer(NbMakeWriter(nb))
        .with_filter(tracing_subscriber::filter::LevelFilter::DEBUG);
    Some(layer)
}
