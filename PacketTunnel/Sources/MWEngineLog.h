#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Severity levels mirroring `meow_core_log`'s contract (Rust `tracing`):
/// 0 = error, 1 = warn, 2 = info, 3 = debug, 4 = trace.
typedef NS_ENUM(int, MWLogLevel) {
    MWLogError = 0,
    MWLogWarn = 1,
    MWLogInfo = 2,
    MWLogDebug = 3,
    MWLogTrace = 4,
};

/// Tee a NetworkExtension-host log line into the engine's `tracing` pipeline so
/// it lands in `<app-group>/logs/meow-tunnel.log` (and os_log, and the REST
/// `/logs` stream) interleaved with engine output. The app's log export reads
/// that file — `OSLogStore` can only see the app's own process, never this one.
///
/// This does not replace the existing `os_log` calls; it runs alongside them so
/// the unified log keeps full live-debugging detail while the exportable file
/// captures the NE lifecycle narrative (start/stop, sleep/wake, path changes).
///
/// Safe to call before the engine starts — the line is simply dropped until the
/// tracing subscriber is installed.
void MWEngineLog(MWLogLevel level, NSString *msg);

/// `NSLog`-style variadic convenience over `MWEngineLog`.
void MWEngineLogf(MWLogLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

NS_ASSUME_NONNULL_END
