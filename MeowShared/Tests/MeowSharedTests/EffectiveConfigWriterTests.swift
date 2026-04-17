import Foundation
@testable import MeowModels
import Testing
import Yams

@Suite("EffectiveConfigWriter")
struct EffectiveConfigWriterTests {
    @Test
    func `strips dns and subscriptions top-level blocks`() throws {
        let source = """
        dns:
          enable: true
          nameserver:
            - 8.8.8.8
        subscriptions:
          - url: https://example.com/a.yaml
        proxies:
          - name: n1
            type: ss
            server: 1.2.3.4
            port: 443
            cipher: aes-256-gcm
            password: p
        """
        let out = try EffectiveConfigWriter.patch(sourceYAML: source, prefs: Preferences())
        #expect(!out.contains("nameserver"))
        #expect(!out.contains("subscriptions:"))
        #expect(out.contains("proxies:"))
    }

    @Test
    func `pins mixed-port from preferences`() throws {
        let source = "proxies: []\n"
        var prefs = Preferences()
        prefs.mixedPort = 17890
        let out = try EffectiveConfigWriter.patch(sourceYAML: source, prefs: prefs)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 17890)
    }

    @Test
    func `defaults mixed-port to 7890 when preference is zero`() throws {
        var prefs = Preferences()
        prefs.mixedPort = 0
        let out = try EffectiveConfigWriter.patch(sourceYAML: "proxies: []\n", prefs: prefs)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
    }

    @Test
    func `pins external-controller to loopback:9090`() throws {
        let out = try EffectiveConfigWriter.patch(sourceYAML: "proxies: []\n", prefs: Preferences())
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["external-controller"] as? String == "127.0.0.1:9090")
    }

    @Test
    func `injects geox-url when missing`() throws {
        let out = try EffectiveConfigWriter.patch(sourceYAML: "proxies: []\n", prefs: Preferences())
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        let geo = parsed?["geox-url"] as? [String: String]
        #expect(geo?["geoip"]?.contains("jsdelivr.net") == true)
        #expect(geo?["geosite"]?.contains("geosite.dat") == true)
        #expect(geo?["mmdb"]?.contains("country.mmdb") == true)
    }

    @Test
    func `preserves user-supplied geox-url`() throws {
        let source = """
        proxies: []
        geox-url:
          geoip: https://example.com/custom.metadb
          geosite: https://example.com/custom.dat
          mmdb: https://example.com/custom.mmdb
        """
        let out = try EffectiveConfigWriter.patch(sourceYAML: source, prefs: Preferences())
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        let geo = parsed?["geox-url"] as? [String: String]
        #expect(geo?["geoip"] == "https://example.com/custom.metadb")
        #expect(geo?["geosite"] == "https://example.com/custom.dat")
    }

    @Test
    func `empty source yields minimal effective config`() throws {
        let out = try EffectiveConfigWriter.patch(sourceYAML: "", prefs: Preferences())
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
        #expect(parsed?["external-controller"] as? String == "127.0.0.1:9090")
    }

    @Test
    func `overrides existing mixed-port and external-controller`() throws {
        let source = """
        mixed-port: 1080
        external-controller: 10.0.0.1:9999
        proxies: []
        """
        let out = try EffectiveConfigWriter.patch(sourceYAML: source, prefs: Preferences())
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
        #expect(parsed?["external-controller"] as? String == "127.0.0.1:9090")
    }

    @Test
    func `write() persists effective config to destination`() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "effective-test-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try EffectiveConfigWriter.write(
            sourceYAML: "proxies: []\n",
            to: tmp,
            prefs: Preferences(),
        )
        let written = try String(contentsOf: tmp, encoding: .utf8)
        let parsed = try Yams.load(yaml: written) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
    }
}
