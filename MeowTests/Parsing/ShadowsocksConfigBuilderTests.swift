import Foundation
@testable import meow_ios
import Testing
import Yams

/// Template rendering for locally added Shadowsocks servers: injection into
/// `proxies` and the 默认 group, per-domain fake-IP / sniffer / DIRECT-rule
/// entries, type-safe scalar quoting, and the extract → render round-trip
/// that lets repeated adds accumulate into one profile.
@Suite("Shadowsocks config builder", .tags(.parsing))
struct ShadowsocksConfigBuilderTests {
    private let echServer = ShadowsocksServer(
        name: "🇸🇬 ech-sgp",
        server: "sgp.example.com",
        port: 443,
        cipher: "aes-128-gcm",
        password: "secret-password",
        udp: false,
        plugin: "ech-tls-tunnel",
        pluginOpts: [
            .init("mode", "client"),
            .init("sni", "sgp.example.com"),
            .init("path", "/ws-abc"),
            .init("ech_config", "QUJDRA=="),
            .init("fingerprint", "chrome"),
            .init("fast_open", "true"),
        ],
    )

    private let plainServer = ShadowsocksServer(
        name: "plain",
        server: "192.0.2.10",
        port: 8388,
        cipher: "aes-256-gcm",
        password: "12345",
        udp: true,
    )

    @Test
    func `rendered config carries marker and injects server into proxies and default group`() throws {
        let yaml = try ShadowsocksConfigBuilder.render(servers: [echServer])
        #expect(ShadowsocksConfigBuilder.isGenerated(yaml))

        let root = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        let proxies = try #require(root["proxies"] as? [[String: Any]])
        #expect(proxies.count == 2)
        #expect(proxies[0]["type"] as? String == "direct")
        let ss = try #require(proxies.last)
        #expect(ss["name"] as? String == "🇸🇬 ech-sgp")
        #expect(ss["type"] as? String == "ss")
        #expect(ss["server"] as? String == "sgp.example.com")
        #expect(ss["port"] as? Int == 443)
        #expect(ss["plugin"] as? String == "ech-tls-tunnel")
        let opts = try #require(ss["plugin-opts"] as? [String: Any])
        #expect(opts["mode"] as? String == "client")
        #expect(opts["ech_config"] as? String == "QUJDRA==")
        #expect(opts["fast_open"] as? Bool == true)

        let groups = try #require(root["proxy-groups"] as? [[String: Any]])
        let defaultGroup = try #require(groups.first { $0["name"] as? String == "默认" })
        let members = try #require(defaultGroup["proxies"] as? [String])
        // After 自动选择 + 直连, before the region groups.
        #expect(members[2] == "🇸🇬 ech-sgp")

        // Providers from the desktop reference config must not leak through.
        #expect(root["proxy-providers"] == nil)
    }

    @Test
    func `domain hosts get fake-ip-filter, sniffer skip, and DIRECT rule; IP hosts do not`() throws {
        let yaml = try ShadowsocksConfigBuilder.render(servers: [echServer, plainServer])
        let root = try #require(try Yams.load(yaml: yaml) as? [String: Any])

        let dns = try #require(root["dns"] as? [String: Any])
        let fakeIPFilter = try #require(dns["fake-ip-filter"] as? [String])
        #expect(fakeIPFilter.contains("+.sgp.example.com"))
        #expect(!fakeIPFilter.contains("+.192.0.2.10"))

        let sniffer = try #require(root["sniffer"] as? [String: Any])
        let skip = try #require(sniffer["skip-domain"] as? [String])
        #expect(skip.contains("+.sgp.example.com"))

        let rules = try #require(root["rules"] as? [String])
        #expect(rules.first == "GEOIP,lan,直连,no-resolve")
        #expect(rules[1] == "DOMAIN-SUFFIX,sgp.example.com,直连")
        #expect(!rules.contains { $0.contains("192.0.2.10") })
        #expect(rules.last == "MATCH,其他")
    }

    @Test
    func `numeric-looking passwords stay strings`() throws {
        let yaml = try ShadowsocksConfigBuilder.render(servers: [plainServer])
        let root = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        let proxies = try #require(root["proxies"] as? [[String: Any]])
        let ss = try #require(proxies.last)
        #expect(ss["password"] as? String == "12345")
        #expect(ss["udp"] as? Bool == true)
    }

    @Test
    func `extractServers round-trips a rendered config`() throws {
        let servers = [echServer, plainServer]
        let yaml = try ShadowsocksConfigBuilder.render(servers: servers)
        let extracted = ShadowsocksConfigBuilder.extractServers(from: yaml)
        #expect(extracted == servers)
    }

    @Test
    func `rendered config passes the structural linter`() throws {
        let yaml = try ShadowsocksConfigBuilder.render(servers: [echServer, plainServer])
        let diagnostics = ClashConfigLinter.lint(yaml)
        #expect(diagnostics.isEmpty, "unexpected lint issues: \(diagnostics)")
    }

    @Test(.tags(.ffi))
    func `rendered config passes engine validation`() throws {
        let yaml = try ShadowsocksConfigBuilder.render(servers: [echServer, plainServer])
        try MeowConfigValidator.validate(yaml)
    }

    @Test(.tags(.ffi))
    func `obfs and v2ray-plugin servers render and pass engine validation`() throws {
        let obfsServer = ShadowsocksServer(
            name: "obfs-node",
            server: "obfs.example.com",
            port: 8388,
            cipher: "aes-256-gcm",
            password: "pw",
            plugin: "obfs",
            pluginOpts: [.init("mode", "http"), .init("host", "www.bing.com")],
        )
        let v2rayServer = ShadowsocksServer(
            name: "ws-node",
            server: "ws.example.com",
            port: 443,
            cipher: "chacha20-ietf-poly1305",
            password: "pw",
            plugin: "v2ray-plugin",
            pluginOpts: [
                .init("mode", "websocket"),
                .init("tls", "true"),
                .init("host", "cdn.example.com"),
                .init("path", "/ws"),
                .init("mux", "true"),
            ],
        )
        let yaml = try ShadowsocksConfigBuilder.render(servers: [obfsServer, v2rayServer])
        try MeowConfigValidator.validate(yaml)

        // Booleans must reach the engine as YAML bools, and the round-trip
        // that repeated adds rely on must preserve both plugin blocks.
        let root = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        let proxies = try #require(root["proxies"] as? [[String: Any]])
        let ws = try #require(proxies.first { $0["name"] as? String == "ws-node" })
        let opts = try #require(ws["plugin-opts"] as? [String: Any])
        #expect(opts["tls"] as? Bool == true)
        #expect(opts["mux"] as? Bool == true)
        #expect(ShadowsocksConfigBuilder.extractServers(from: yaml) == [obfsServer, v2rayServer])
    }
}
