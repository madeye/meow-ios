import Foundation

// keep in sync with PacketTunnel/Sources/MWPreferences.h MWPrefKey* constants

/// Keys used for preferences shared via the App Group UserDefaults suite.
public enum PreferenceKey {
    public static let mixedPort = "com.meow.mixedPort"
    public static let logLevel = "com.meow.logLevel"
    public static let allowLan = "com.meow.allowLan"
    public static let ipv6 = "com.meow.ipv6"
    public static let onDemand = "com.meow.onDemand"
    public static let pendingIntent = "com.meow.pendingIntent"
    public static let selectedProfileID = "com.meow.selectedProfileID"
    public static let apiSecret = "com.meow.apiSecret"
}

public enum PreferenceDefaults {
    public static let mixedPort: Int = 7890
    public static let logLevel: String = "info"
    public static let allowLan: Bool = false
    public static let ipv6: Bool = false
    public static let onDemand: Bool = false
}

public struct Preferences: Sendable {
    public var mixedPort: Int
    public var logLevel: String
    public var allowLan: Bool
    public var ipv6: Bool
    public var onDemand: Bool

    public init(
        mixedPort: Int = PreferenceDefaults.mixedPort,
        logLevel: String = PreferenceDefaults.logLevel,
        allowLan: Bool = PreferenceDefaults.allowLan,
        ipv6: Bool = PreferenceDefaults.ipv6,
        onDemand: Bool = PreferenceDefaults.onDemand,
    ) {
        self.mixedPort = mixedPort
        self.logLevel = logLevel
        self.allowLan = allowLan
        self.ipv6 = ipv6
        self.onDemand = onDemand
    }

    public static func load(from defaults: UserDefaults) -> Preferences {
        var prefs = Preferences()
        if defaults.object(forKey: PreferenceKey.mixedPort) != nil {
            prefs.mixedPort = defaults.integer(forKey: PreferenceKey.mixedPort)
        }
        prefs.logLevel = defaults.string(forKey: PreferenceKey.logLevel) ?? PreferenceDefaults.logLevel
        if defaults.object(forKey: PreferenceKey.allowLan) != nil {
            prefs.allowLan = defaults.bool(forKey: PreferenceKey.allowLan)
        }
        if defaults.object(forKey: PreferenceKey.ipv6) != nil {
            prefs.ipv6 = defaults.bool(forKey: PreferenceKey.ipv6)
        }
        if defaults.object(forKey: PreferenceKey.onDemand) != nil {
            prefs.onDemand = defaults.bool(forKey: PreferenceKey.onDemand)
        }
        return prefs
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(mixedPort, forKey: PreferenceKey.mixedPort)
        defaults.set(logLevel, forKey: PreferenceKey.logLevel)
        defaults.set(allowLan, forKey: PreferenceKey.allowLan)
        defaults.set(ipv6, forKey: PreferenceKey.ipv6)
        defaults.set(onDemand, forKey: PreferenceKey.onDemand)
    }
}
