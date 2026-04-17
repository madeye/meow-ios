import Foundation
@testable import MeowModels
import Testing

@Suite("Preferences round-trip")
struct PreferencesTests {
    @Test
    func `defaults are applied when keys are missing`() throws {
        let defaults = try #require(UserDefaults(suiteName: "preferences-test-defaults"))
        defaults.removePersistentDomain(forName: "preferences-test-defaults")
        let prefs = Preferences.load(from: defaults)
        #expect(prefs.mixedPort == PreferenceDefaults.mixedPort)
        #expect(prefs.logLevel == PreferenceDefaults.logLevel)
        #expect(prefs.allowLan == false)
    }

    @Test
    func `save then load preserves values`() throws {
        let defaults = try #require(UserDefaults(suiteName: "preferences-test-rt"))
        defaults.removePersistentDomain(forName: "preferences-test-rt")
        var prefs = Preferences()
        prefs.mixedPort = 9999
        prefs.dohServer = "https://dns.example/dns-query"
        prefs.allowLan = true
        prefs.save(to: defaults)
        let loaded = Preferences.load(from: defaults)
        #expect(loaded.mixedPort == 9999)
        #expect(loaded.dohServer == "https://dns.example/dns-query")
        #expect(loaded.allowLan == true)
    }
}
