//! os_log-backed logger. Replaces the Android `android_logger` crate.

use log::info;
use std::sync::Once;

static INIT: Once = Once::new();

/// Initialize the os_log bridge. Safe to call more than once.
pub fn init_os_logger() {
    INIT.call_once(|| {
        // The subsystem is the extension's bundle id. Logs flow to Apple's
        // unified logging and can be viewed via `log stream` on macOS or the
        // Console app while a device is attached.
        let subsystem = "io.github.madeye.meow.PacketTunnel";
        if let Err(e) =
            oslog::OsLogger::new(subsystem).level_filter(log::LevelFilter::Debug).init()
        {
            eprintln!("oslog init failed: {}", e);
        }
    });
}

pub fn bridge_log(msg: &str) {
    info!("{}", msg);
}
