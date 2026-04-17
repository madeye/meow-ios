import Foundation

/// Shared App Group identifier used by the app and the packet-tunnel extension.
public enum AppGroup {
    public static let identifier = "group.io.github.madeye.meow"

    /// Root of the shared container visible to both processes.
    public static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group container unavailable — entitlements missing '\(identifier)'")
        }
        return url
    }

    /// User-visible Clash YAML — what the app writes from the active profile.
    public static var configURL: URL { containerURL.appending(path: "config.yaml") }

    /// Patched copy consumed by the engine: mixed-port / external-controller
    /// pinned, `dns:` + `subscriptions:` stripped, `geox-url:` injected. The
    /// extension writes this at start time so the user's original YAML stays
    /// intact in `configURL`.
    public static var effectiveConfigURL: URL { containerURL.appending(path: "effective-config.yaml") }

    public static var stateURL: URL { containerURL.appending(path: "state.json") }
    public static var trafficURL: URL { containerURL.appending(path: "traffic.json") }
    public static var assetsDir: URL { containerURL.appending(path: "assets", directoryHint: .isDirectory) }
    public static var geoIPURL: URL { assetsDir.appending(path: "geoip.metadb") }
    public static var geositeURL: URL { assetsDir.appending(path: "geosite.dat") }
    public static var countryURL: URL { assetsDir.appending(path: "country.mmdb") }

    /// UserDefaults suite shared between app and extension. Force-unwrap is
    /// safe once entitlements are wired — missing suite indicates a config bug
    /// that should fail loudly.
    public static var defaults: UserDefaults {
        guard let d = UserDefaults(suiteName: identifier) else {
            fatalError("Shared UserDefaults unavailable for suite '\(identifier)'")
        }
        return d
    }
}
