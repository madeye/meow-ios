import Foundation
import Yams

/// Transforms a user Clash YAML profile into the effective config the engine
/// actually loads. Mirrors the Android `MihomoInstance.start` pipeline:
///
///   1. Remove user-managed `dns:` and `subscriptions:` blocks — the extension
///      owns DNS (DoH + fake-ip) and the app owns subscription fetching.
///   2. Pin `mixed-port` (defaults to 7890) so the tun2socks dispatcher and the
///      REST API know the listener port without consulting the YAML.
///   3. Pin `external-controller: 127.0.0.1:9090` so the app can talk to the
///      engine's REST API over loopback.
///   4. Inject a `geox-url:` block (jsDelivr-hosted) when the user didn't
///      provide one, so the engine has somewhere to fetch geoip/geosite from.
///
/// The source YAML stays intact in `AppGroup.configURL`; the patched output
/// goes to `AppGroup.effectiveConfigURL`.
public enum EffectiveConfigWriter {
    public static let defaultMixedPort = 7890
    public static let defaultExternalController = "127.0.0.1:9090"

    /// Matches the Android client's jsDelivr mirrors of the MetaCubeX databases.
    public static let defaultGeoXURL: [String: String] = [
        "geoip": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "mmdb": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb",
        "geosite": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
    ]

    public static func write(
        sourceYAML: String,
        to destination: URL,
        prefs: Preferences
    ) throws {
        let effective = try patch(sourceYAML: sourceYAML, prefs: prefs)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try effective.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// Pure patcher — exposed for unit tests. Returns the effective YAML text.
    public static func patch(sourceYAML: String, prefs: Preferences) throws -> String {
        let loaded = try Yams.load(yaml: sourceYAML)
        var root: [String: Any] = (loaded as? [String: Any]) ?? [:]

        root.removeValue(forKey: "dns")
        root.removeValue(forKey: "subscriptions")

        let mixedPort = prefs.mixedPort > 0 ? prefs.mixedPort : defaultMixedPort
        root["mixed-port"] = mixedPort
        root["external-controller"] = defaultExternalController

        if root["geox-url"] == nil {
            root["geox-url"] = defaultGeoXURL
        }

        // Stable key ordering so the effective file diffs cleanly across
        // restarts, and mihomo-rust doesn't care about input key order.
        return try Yams.dump(object: root, sortKeys: true)
    }
}
