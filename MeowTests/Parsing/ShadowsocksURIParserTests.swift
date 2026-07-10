import Foundation
@testable import meow_ios
import Testing

/// `ss://` share-link parsing (manual paste + QR scan payloads): SIP002 with
/// base64url or plain userinfo, the legacy whole-body-base64 form, and the
/// SIP003 `plugin` query parameter used by ech-tls-tunnel QR codes.
@Suite("Shadowsocks URI parser", .tags(.parsing))
struct ShadowsocksURIParserTests {
    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private func base64URLNoPad(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test
    func `parses SIP002 with padded base64 userinfo and fragment name`() throws {
        let uri = "ss://\(base64("aes-128-gcm:secret!pw"))@example.com:8443#My%20Node"
        let server = try ShadowsocksURIParser.parse(uri)
        #expect(server.name == "My Node")
        #expect(server.server == "example.com")
        #expect(server.port == 8443)
        #expect(server.cipher == "aes-128-gcm")
        #expect(server.password == "secret!pw")
        #expect(server.plugin == nil)
        #expect(server.udp == false)
    }

    @Test
    func `parses SIP002 with unpadded base64url userinfo`() throws {
        // "chacha20-ietf-poly1305:pa>ss" encodes to base64 needing both
        // URL-safe substitution and re-padding.
        let uri = "ss://\(base64URLNoPad("chacha20-ietf-poly1305:pa>ss"))@10.0.0.2:443"
        let server = try ShadowsocksURIParser.parse(uri)
        #expect(server.cipher == "chacha20-ietf-poly1305")
        #expect(server.password == "pa>ss")
        #expect(server.server == "10.0.0.2")
        #expect(server.port == 443)
        // No fragment → engine-style default name.
        #expect(server.name == "ss-10.0.0.2-443")
    }

    @Test
    func `parses SIP002 plain userinfo used by SS-2022 ciphers`() throws {
        let uri = "ss://2022-blake3-aes-256-gcm:MTIzNDU2Nzg5MDEyMzQ1Ng%3D%3D@host.example.net:443#n1"
        let server = try ShadowsocksURIParser.parse(uri)
        #expect(server.cipher == "2022-blake3-aes-256-gcm")
        #expect(server.password == "MTIzNDU2Nzg5MDEyMzQ1Ng==")
        #expect(server.server == "host.example.net")
    }

    @Test
    func `parses SIP003 plugin query into plugin and ordered options`() throws {
        let plugin = "ech-tls-tunnel;mode=client;sni=sgp.example.com;path=/ws-abc"
            + ";ech_config=QUJDRA==;fingerprint=chrome;fast_open"
        var comps = URLComponents(string: "ss://\(base64("aes-128-gcm:pw"))@sgp.example.com:443")!
        comps.queryItems = [URLQueryItem(name: "plugin", value: plugin)]
        comps.fragment = "ech-sgp"
        let server = try ShadowsocksURIParser.parse(comps.string!)
        #expect(server.name == "ech-sgp")
        #expect(server.plugin == "ech-tls-tunnel")
        #expect(server.pluginOption("mode") == "client")
        #expect(server.pluginOption("sni") == "sgp.example.com")
        #expect(server.pluginOption("path") == "/ws-abc")
        #expect(server.pluginOption("ech_config") == "QUJDRA==")
        #expect(server.pluginOption("fingerprint") == "chrome")
        // Bare SIP003 flag decodes as boolean true.
        #expect(server.pluginOption("fast_open") == "true")
    }

    @Test
    func `parses legacy whole-body base64 form`() throws {
        let uri = "ss://\(base64("aes-256-gcm:p@ss:word@1.2.3.4:8388"))#Legacy%20Node"
        let server = try ShadowsocksURIParser.parse(uri)
        #expect(server.name == "Legacy Node")
        #expect(server.cipher == "aes-256-gcm")
        // Password containing '@' and ':' survives the last-@/first-: split.
        #expect(server.password == "p@ss:word")
        #expect(server.server == "1.2.3.4")
        #expect(server.port == 8388)
    }

    @Test
    func `parses IPv6 host in brackets`() throws {
        let uri = "ss://\(base64("aes-128-gcm:pw"))@[2001:db8::1]:443#v6"
        let server = try ShadowsocksURIParser.parse(uri)
        #expect(server.server == "2001:db8::1")
        #expect(server.port == 443)
    }

    @Test
    func `rejects non-ss schemes and garbage payloads`() {
        #expect(throws: ShadowsocksURIParser.ParseError.notShadowsocks) {
            try ShadowsocksURIParser.parse("trojan://x@example.com:443")
        }
        #expect(throws: ShadowsocksURIParser.ParseError.self) {
            try ShadowsocksURIParser.parse("ss://%%%not-base64%%%")
        }
        #expect(throws: ShadowsocksURIParser.ParseError.self) {
            // SIP002 shape but no port.
            try ShadowsocksURIParser.parse("ss://\(base64("aes-128-gcm:pw"))@example.com")
        }
    }
}
