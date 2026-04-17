import Foundation

/// Keys used for preferences shared via the App Group UserDefaults suite.
public enum PreferenceKey {
    public static let mixedPort = "com.meow.mixedPort"
    public static let localDnsPort = "com.meow.localDnsPort"
    public static let dohServer = "com.meow.dohServer"
    public static let logLevel = "com.meow.logLevel"
    public static let allowLan = "com.meow.allowLan"
    public static let ipv6 = "com.meow.ipv6"
    public static let perAppMode = "com.meow.perAppMode"
    public static let perAppPackages = "com.meow.perAppPackages"
    public static let pendingIntent = "com.meow.pendingIntent"
    public static let selectedProfileID = "com.meow.selectedProfileID"
    public static let apiSecret = "com.meow.apiSecret"
}

public enum PreferenceDefaults {
    public static let mixedPort: Int = 7890
    public static let localDnsPort: Int = 1053
    public static let dohServer: String = ""
    public static let logLevel: String = "info"
    public static let allowLan: Bool = false
    public static let ipv6: Bool = false
    public static let perAppMode: String = "proxy"
}

public struct Preferences: Sendable {
    public var mixedPort: Int
    public var localDnsPort: Int
    public var dohServer: String
    public var logLevel: String
    public var allowLan: Bool
    public var ipv6: Bool

    public init(
        mixedPort: Int = PreferenceDefaults.mixedPort,
        localDnsPort: Int = PreferenceDefaults.localDnsPort,
        dohServer: String = PreferenceDefaults.dohServer,
        logLevel: String = PreferenceDefaults.logLevel,
        allowLan: Bool = PreferenceDefaults.allowLan,
        ipv6: Bool = PreferenceDefaults.ipv6,
    ) {
        self.mixedPort = mixedPort
        self.localDnsPort = localDnsPort
        self.dohServer = dohServer
        self.logLevel = logLevel
        self.allowLan = allowLan
        self.ipv6 = ipv6
    }

    public static func load(from defaults: UserDefaults) -> Preferences {
        var prefs = Preferences()
        if defaults.object(forKey: PreferenceKey.mixedPort) != nil {
            prefs.mixedPort = defaults.integer(forKey: PreferenceKey.mixedPort)
        }
        if defaults.object(forKey: PreferenceKey.localDnsPort) != nil {
            prefs.localDnsPort = defaults.integer(forKey: PreferenceKey.localDnsPort)
        }
        prefs.dohServer = defaults.string(forKey: PreferenceKey.dohServer) ?? PreferenceDefaults.dohServer
        prefs.logLevel = defaults.string(forKey: PreferenceKey.logLevel) ?? PreferenceDefaults.logLevel
        if defaults.object(forKey: PreferenceKey.allowLan) != nil {
            prefs.allowLan = defaults.bool(forKey: PreferenceKey.allowLan)
        }
        if defaults.object(forKey: PreferenceKey.ipv6) != nil {
            prefs.ipv6 = defaults.bool(forKey: PreferenceKey.ipv6)
        }
        return prefs
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(mixedPort, forKey: PreferenceKey.mixedPort)
        defaults.set(localDnsPort, forKey: PreferenceKey.localDnsPort)
        defaults.set(dohServer, forKey: PreferenceKey.dohServer)
        defaults.set(logLevel, forKey: PreferenceKey.logLevel)
        defaults.set(allowLan, forKey: PreferenceKey.allowLan)
        defaults.set(ipv6, forKey: PreferenceKey.ipv6)
    }
}
