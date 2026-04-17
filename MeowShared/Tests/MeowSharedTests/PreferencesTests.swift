import Testing
import Foundation
@testable import MeowModels

@Suite("Preferences round-trip")
struct PreferencesTests {
    @Test("defaults are applied when keys are missing")
    func testDefaults() {
        let defaults = UserDefaults(suiteName: "preferences-test-defaults")!
        defaults.removePersistentDomain(forName: "preferences-test-defaults")
        let prefs = Preferences.load(from: defaults)
        #expect(prefs.mixedPort == PreferenceDefaults.mixedPort)
        #expect(prefs.logLevel == PreferenceDefaults.logLevel)
        #expect(prefs.allowLan == false)
    }

    @Test("save then load preserves values")
    func testRoundTrip() {
        let defaults = UserDefaults(suiteName: "preferences-test-rt")!
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
