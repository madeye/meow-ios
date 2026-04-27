//! os_log-backed logger. Replaces the Android `android_logger` crate.
//!
//! mihomo-rust uses `tracing` throughout; our oslog bridge sits on `log`.
//! `LogForwardLayer` is a `tracing_subscriber::Layer` that forwards every
//! tracing event to `log::log!` so engine output reaches the Apple unified
//! log through the same pipe as our own `logging::bridge_log` calls. Installed
//! from `engine::start` alongside `mihomo_api::log_stream::LogBroadcastLayer`
//! (the latter powers the REST `/logs` WebSocket).

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

/// Route Rust panics to os_log before the runtime aborts. Without this hook
/// the panic message goes to stderr only, which NetworkExtension does not
/// capture — the iOS crash report shows just the backtrace, not the message.
/// Safe to call more than once.
pub fn install_panic_hook() {
    static INSTALLED: Once = Once::new();
    INSTALLED.call_once(|| {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let location = info
                .location()
                .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
                .unwrap_or_else(|| "<unknown>".to_string());
            let payload = info.payload();
            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };
            let thread = std::thread::current();
            let thread_name = thread.name().unwrap_or("<unnamed>");
            log::error!(
                "rust panic in thread '{}' at {}: {}",
                thread_name,
                location,
                msg
            );
            default_hook(info);
        }));
    });
}

// ---------------------------------------------------------------------------
// tracing → log bridge
// ---------------------------------------------------------------------------

/// Forwards every tracing event to `log::log!` so mihomo-rust's
/// `tracing::{info,warn,error,debug,trace}!` calls reach the oslog bridge.
/// Field-recording matches `LogBroadcastLayer::MessageVisitor` — only the
/// `message` field becomes the log line; structured fields are dropped
/// (oslog doesn't render them anyway).
pub struct LogForwardLayer;

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for LogForwardLayer {
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let level = match *event.metadata().level() {
            tracing::Level::TRACE => log::Level::Trace,
            tracing::Level::DEBUG => log::Level::Debug,
            tracing::Level::INFO => log::Level::Info,
            tracing::Level::WARN => log::Level::Warn,
            tracing::Level::ERROR => log::Level::Error,
        };
        let target = event.metadata().target();
        if !log::log_enabled!(target: target, level) {
            return;
        }
        let mut visitor = MessageVisitor(String::new());
        event.record(&mut visitor);
        log::log!(target: target, level, "{}", visitor.0);
    }
}

struct MessageVisitor(String);

impl tracing::field::Visit for MessageVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.0 = format!("{:?}", value);
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.0 = value.to_string();
        }
    }
}
