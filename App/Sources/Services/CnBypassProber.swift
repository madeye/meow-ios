import Foundation
import MeowModels
import os

/// Pre-connect CN-bypass probe.
///
/// Calls `meow_config_cn_bypass_probe` (meow-ios-ffi) on the active config:
/// a functional rule-matching test that routes representative mainland-China
/// IPs through the parsed rule chain and, when every one of them hits a
/// `GEOIP,CN` rule resolving to a DIRECT terminal, writes the merged CN CIDR
/// set (plus a SHA-256 of the config it probed) into an App Group artifact.
/// The packet-tunnel extension reads that artifact at start and excludes the
/// CN routes from the TUN, keeping mainland traffic on the physical
/// interface instead of relaying it through the netstack just to be
/// DIRECT-dialed again.
///
/// Runs in the app process on purpose: the config load + Country.mmdb walk
/// is a transient multi-MB allocation the extension's ~50 MB jetsam budget
/// should never pay. The artifact's SHA gate makes a skipped or failed probe
/// safe — the extension falls back to full-tunnel routing whenever the
/// artifact doesn't match the config it is about to run.
enum CnBypassProber {
    private static let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "cn-bypass")

    /// Probe `configURL` and (re)write the artifact at `artifactURL`.
    /// Blocking (config load + MMDB walk, typically well under a second) —
    /// call off the main actor. Returns whether the bypass engaged; failures
    /// only log, because the worst case is full-tunnel routing, which is
    /// today's behavior.
    @discardableResult
    static func probe(
        configURL: URL = AppGroup.configURL,
        artifactURL: URL = AppGroup.cnBypassURL,
    ) -> Bool {
        let rc = meow_config_cn_bypass_probe(configURL.path, artifactURL.path)
        switch rc {
        case 1:
            log.info("CN bypass engaged — artifact written to \(artifactURL.lastPathComponent)")
            return true
        case 0:
            log.info("CN bypass not applicable for the active config")
            return false
        default:
            let message = meow_core_last_error().map { String(cString: $0) } ?? "unknown"
            log.error("CN bypass probe failed: \(message, privacy: .public)")
            return false
        }
    }
}
