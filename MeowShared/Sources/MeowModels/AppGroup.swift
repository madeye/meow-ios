import Foundation

/// Shared App Group identifier used by the app and the packet-tunnel extension.
public enum AppGroup {
    /// Authored identifier as declared in the .entitlements files. Apple-signed
    /// builds (TestFlight / App Store) preserve this verbatim — the embedded
    /// provisioning profile is absent on App Store builds, so `identifier`
    /// resolves to this constant. Sideloaders (AltStore / SideStore) rewrite
    /// the app-group entitlement to append the installer's team prefix.
    public static let authoredIdentifier = "group.io.github.madeye.meow"

    /// Live app-group identifier. For Ad Hoc / Development / Enterprise builds
    /// we read the first `com.apple.security.application-groups` entry out of
    /// the bundle's `embedded.mobileprovision`, which is where AltStore's
    /// team-prefix rewrite lands. App Store builds strip that file, so we fall
    /// back to `authoredIdentifier` — fine because Apple signs with the
    /// authoring team and the identifier is preserved verbatim.
    public static let identifier: String = resolveIdentifier()

    private static func resolveIdentifier() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let ascii = String(data: data, encoding: .ascii),
              let start = ascii.range(of: "<plist"),
              let end = ascii.range(of: "</plist>", range: start.upperBound ..< ascii.endIndex)
        else {
            return authoredIdentifier
        }
        let plistSlice = Data(ascii[start.lowerBound ..< end.upperBound].utf8)
        guard
            let parsed = try? PropertyListSerialization.propertyList(from: plistSlice, format: nil),
            let plist = parsed as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let groups = entitlements["com.apple.security.application-groups"] as? [String],
            let first = groups.first
        else {
            return authoredIdentifier
        }
        return first
    }

    /// Root of the shared container visible to both processes.
    public static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group container unavailable — entitlements missing '\(identifier)'")
        }
        return url
    }

    /// User-visible Clash YAML — what the app writes from the active profile.
    public static var configURL: URL {
        containerURL.appending(path: "config.yaml")
    }

    /// Patched copy consumed by the engine: mixed-port / external-controller
    /// pinned, `dns:` + `subscriptions:` stripped, `geox-url:` injected. The
    /// extension writes this at start time so the user's original YAML stays
    /// intact in `configURL`.
    public static var effectiveConfigURL: URL {
        containerURL.appending(path: "effective-config.yaml")
    }

    public static var stateURL: URL {
        containerURL.appending(path: "state.json")
    }

    public static var trafficURL: URL {
        containerURL.appending(path: "traffic.json")
    }

    /// Directory the engine treats as its "config home": mirrors the layout
    /// `mihomo-config` expects under `$XDG_CONFIG_HOME/mihomo`, which the FFI
    /// layer points at `containerURL` via `meow_core_set_home_dir`.
    public static var mihomoConfigDir: URL {
        containerURL.appending(path: "mihomo", directoryHint: .isDirectory)
    }

    /// Location `mihomo-config::default_geoip_path()` resolves to once
    /// `XDG_CONFIG_HOME=containerURL` is exported. Capital-C filename matches
    /// the engine's lookup.
    public static var countryMmdbURL: URL {
        mihomoConfigDir.appending(path: "Country.mmdb")
    }

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
