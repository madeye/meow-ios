import Foundation
@testable import MeowModels
import Testing
import Yams

@Suite("EffectiveConfigWriter")
struct EffectiveConfigWriterTests {
    private static let apiCredentials = EffectiveConfigWriter.APICredentials(
        port: 54321,
        secret: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )

    private func patch(_ sourceYAML: String, prefs: Preferences = Preferences()) throws -> String {
        try EffectiveConfigWriter.patch(
            sourceYAML: sourceYAML,
            prefs: prefs,
            apiCredentials: Self.apiCredentials,
        )
    }

    @Test
    func `replaces dns and strips subscriptions top-level block`() throws {
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
        let out = try patch(source)
        #expect(!out.contains("subscriptions:"))
        #expect(out.contains("proxies:"))
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        let dns = parsed?["dns"] as? [String: Any]
        #expect(dns?["listen"] as? String == "127.0.0.1:1053")
        #expect((dns?["nameserver"] as? [String]) == ["119.29.29.29", "223.5.5.5"])
    }

    @Test
    func `overrides secret so REST API requires bearer token`() throws {
        let source = """
        secret: "deadbeef-token"
        proxies:
          - name: n1
            type: ss
            server: 1.2.3.4
            port: 443
            cipher: aes-256-gcm
            password: p
        """
        let out = try patch(source)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["secret"] as? String == Self.apiCredentials.secret)
        #expect(out.contains("proxies:"))
    }

    @Test
    func `pins mixed-port from preferences`() throws {
        let source = "proxies: []\n"
        var prefs = Preferences()
        prefs.mixedPort = 17890
        let out = try patch(source, prefs: prefs)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 17890)
    }

    @Test
    func `pins allow-lan and bind-address from preferences`() throws {
        var prefs = Preferences()
        prefs.allowLan = true
        let out = try patch("proxies: []\n", prefs: prefs)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        let dns = parsed?["dns"] as? [String: Any]
        #expect(parsed?["allow-lan"] as? Bool == true)
        #expect(parsed?["bind-address"] as? String == "0.0.0.0")
        #expect(dns?["listen"] as? String == "0.0.0.0:1053")
    }

    @Test
    func `defaults mixed-port to 7890 when preference is zero`() throws {
        var prefs = Preferences()
        prefs.mixedPort = 0
        let out = try patch("proxies: []\n", prefs: prefs)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
    }

    @Test
    func `pins external-controller to credential loopback port`() throws {
        let out = try patch("proxies: []\n")
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["external-controller"] as? String == "127.0.0.1:\(Self.apiCredentials.port)")
    }

    @Test
    func `injects geox-url when missing`() throws {
        let out = try patch("proxies: []\n")
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
        let out = try patch(source)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        let geo = parsed?["geox-url"] as? [String: String]
        #expect(geo?["geoip"] == "https://example.com/custom.metadb")
        #expect(geo?["geosite"] == "https://example.com/custom.dat")
    }

    @Test
    func `empty source yields minimal effective config`() throws {
        let out = try patch("")
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
        #expect(parsed?["external-controller"] as? String == "127.0.0.1:\(Self.apiCredentials.port)")
        #expect(parsed?["secret"] as? String == Self.apiCredentials.secret)
    }

    @Test
    func `overrides existing mixed-port and external-controller`() throws {
        let source = """
        mixed-port: 1080
        external-controller: 10.0.0.1:9999
        proxies: []
        """
        let out = try patch(source)
        let parsed = try Yams.load(yaml: out) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
        #expect(parsed?["external-controller"] as? String == "127.0.0.1:\(Self.apiCredentials.port)")
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
            apiCredentials: Self.apiCredentials,
        )
        let written = try String(contentsOf: tmp, encoding: .utf8)
        let parsed = try Yams.load(yaml: written) as? [String: Any]
        #expect(parsed?["mixed-port"] as? Int == 7890)
    }
}
