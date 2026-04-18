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
