import Foundation

/// Shared App Group identifier used by the app and the packet-tunnel extension.
public enum AppGroup {
    public static let identifier = "group.com.tangzixiang.meow"

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

    /// Active file of the always-on debug ring the engine (`file_log.rs`) and
    /// the NE host (`MWEngineLog`) write while the tunnel runs. The app can't
    /// read the extension's `OSLogStore`, so this shared file is how the in-app
    /// log export includes the tunnel's own output. A `.1`-suffixed sibling
    /// holds the previous rotation. The engine derives this same path from
    /// `meow_core_set_home_dir(containerURL)` + `logs/meow-tunnel.log`.
    public static var tunnelLogURL: URL {
        containerURL.appending(path: "logs", directoryHint: .isDirectory)
            .appending(path: "meow-tunnel.log")
    }

    public static var trafficURL: URL {
        containerURL.appending(path: "traffic.json")
    }

    /// Per-install REST-API credentials minted by the Rust `meow_patch_config`
    /// (random loopback port + bearer secret) and persisted here in the App
    /// Group container. Both the app and the extension read this so the client
    /// authenticates against the port/secret the engine actually bound. The
    /// file is sandboxed to this app group, so the secret never leaks to other
    /// apps. Returns `nil` until the extension has patched a config at least
    /// once (no tunnel ever started) — callers fall back to defaults.
    public static var apiCredentialsURL: URL {
        containerURL.appending(path: "api-credentials.json")
    }

    public struct APICredentials: Decodable {
        public let port: Int
        public let secret: String
    }

    public static func apiCredentials() -> APICredentials? {
        guard let data = try? Data(contentsOf: apiCredentialsURL) else { return nil }
        return try? JSONDecoder().decode(APICredentials.self, from: data)
    }

    /// Directory the engine treats as its "config home": mirrors the layout
    /// `meow-config` expects under `$XDG_CONFIG_HOME/meow`, which the FFI
    /// layer points at `containerURL` via `meow_core_set_home_dir`.
    public static var meowConfigDir: URL {
        containerURL.appending(path: "meow", directoryHint: .isDirectory)
    }

    /// Mark the user's downloaded config and engine data directory as
    /// iCloud-backup-eligible, and exclude transient files that are
    /// regenerated on every tunnel start.
    public static func configureBackup() {
        setBackupExclusion(containerURL, excluded: false)
        setBackupExclusion(configURL, excluded: false)
        setBackupExclusion(meowConfigDir, excluded: false)
        setBackupExclusion(effectiveConfigURL, excluded: true)
        setBackupExclusion(stateURL, excluded: true)
        setBackupExclusion(trafficURL, excluded: true)
        // The REST-API credentials are a per-install secret regenerated on
        // demand — never sync them to iCloud.
        setBackupExclusion(apiCredentialsURL, excluded: true)
        // Transient diagnostic ring, rewritten every run — never back it up.
        setBackupExclusion(tunnelLogURL, excluded: true)
        setBackupExclusion(tunnelLogURL.appendingPathExtension("1"), excluded: true)
    }

    private static func setBackupExclusion(_ url: URL, excluded: Bool) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? u.setResourceValues(values)
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
