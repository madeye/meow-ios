import Foundation
import Yams

/// Transforms a user Clash YAML profile into the effective config the engine
/// actually loads. Mirrors the Android `MeowInstance.start` pipeline:
///
///   1. Remove user-managed `dns:` and `subscriptions:` blocks — the extension
///      owns DNS (fake-ip + local listener) and the app owns subscription fetching.
///   2. Strip `secret:` so the REST API runs open on loopback — the app talks
///      to the engine via `MeowAPI(secret: "")` and would 401 if the user's
///      profile happened to ship a token.
///   3. Pin `mixed-port` (defaults to 7890), `allow-lan`, `bind-address`, and
///      a DNS listener so tun2socks and LAN clients can use meow's listeners.
///   4. Pin `external-controller: 127.0.0.1:9090` so the app can talk to the
///      engine's REST API over loopback.
///   5. Inject a `geox-url:` block (jsDelivr-hosted) when the user didn't
///      provide one, so the engine has somewhere to fetch geoip/geosite from.
///
/// The source YAML stays intact in `AppGroup.configURL`; the patched output
/// goes to `AppGroup.effectiveConfigURL`.
public enum EffectiveConfigWriter {
    public static let defaultMixedPort = 7890
    public static let defaultDNSPort = 1053
    public static let defaultExternalController = "127.0.0.1:9090"

    /// Matches the Android client's jsDelivr mirrors of the MetaCubeX databases.
    /// `asn` is included so subscriptions with `IP-ASN,<num>,<group>` rules work
    /// — without the `GeoLite2-ASN.mmdb` on disk, meow-rs errors out of
    /// engine_start.
    public static let defaultGeoXURL: [String: String] = [
        "geoip": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "mmdb": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb",
        "geosite": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
        "asn": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb",
    ]

    public static func write(
        sourceYAML: String,
        to destination: URL,
        prefs: Preferences,
    ) throws {
        let effective = try patch(sourceYAML: sourceYAML, prefs: prefs)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try effective.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// Pure patcher — exposed for unit tests. Returns the effective YAML text.
    public static func patch(sourceYAML: String, prefs: Preferences) throws -> String {
        let loaded = try Yams.load(yaml: sourceYAML)
        var root: [String: Any] = (loaded as? [String: Any]) ?? [:]

        root.removeValue(forKey: "dns")
        root.removeValue(forKey: "subscriptions")
        root.removeValue(forKey: "secret")

        let mixedPort = prefs.mixedPort > 0 ? prefs.mixedPort : defaultMixedPort
        let bindAddress = prefs.allowLan ? "0.0.0.0" : "127.0.0.1"
        root["mixed-port"] = mixedPort
        root["allow-lan"] = prefs.allowLan
        root["bind-address"] = bindAddress
        root["dns"] = [
            "enable": true,
            "listen": "\(bindAddress):\(defaultDNSPort)",
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "28.0.0.0/8",
            "nameserver": [
                "119.29.29.29",
                "223.5.5.5",
            ],
        ]
        root["external-controller"] = defaultExternalController

        if root["geox-url"] == nil {
            root["geox-url"] = defaultGeoXURL
        }

        // Stable key ordering so the effective file diffs cleanly across
        // restarts, and meow-rs doesn't care about input key order.
        return try Yams.dump(object: root, sortKeys: true)
    }
}
