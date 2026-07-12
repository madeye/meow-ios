import Foundation
@testable import meow_ios
import Testing

/// `ss://` share-link generation for QR export: SIP002 output shapes and,
/// critically, round-tripping through ``ShadowsocksURIParser`` so an exported
/// QR code re-imports as the identical server (`udp` excepted — SIP002 has no
/// representation for it).
@Suite("Shadowsocks URI encoder", .tags(.parsing))
struct ShadowsocksURIEncoderTests {
    /// Round-trip equality modulo `udp`, which the URI format can't carry.
    private func expectRoundTrips(_ server: ShadowsocksServer) throws {
        var reparsed = try ShadowsocksURIParser.parse(ShadowsocksURIEncoder.encode(server))
        reparsed.udp = server.udp
        #expect(reparsed == server)
    }

    @Test
    func `encodes AEAD cipher as base64url userinfo with fragment name`() throws {
        let server = ShadowsocksServer(
            name: "My Node",
            server: "example.com",
            port: 8443,
            cipher: "aes-128-gcm",
            password: "secret!pw",
        )
        let uri = ShadowsocksURIEncoder.encode(server)
        #expect(uri.hasPrefix("ss://"))
        #expect(uri.hasSuffix("#My%20Node"))
        // Userinfo is unpadded base64url, not plain method:password.
        #expect(!uri.contains("aes-128-gcm:"))
        #expect(!uri.contains("="))
        try expectRoundTrips(server)
    }

    @Test
    func `encodes SS-2022 cipher as plain percent-encoded userinfo`() throws {
        let server = ShadowsocksServer(
            name: "n1",
            server: "host.example.net",
            port: 443,
            cipher: "2022-blake3-aes-256-gcm",
            password: "MTIzNDU2Nzg5MDEyMzQ1Ng==",
        )
        let uri = ShadowsocksURIEncoder.encode(server)
        #expect(uri.contains("2022-blake3-aes-256-gcm:MTIzNDU2Nzg5MDEyMzQ1Ng%3D%3D@"))
        try expectRoundTrips(server)
    }

    @Test
    func `brackets IPv6 hosts`() throws {
        let server = ShadowsocksServer(
            name: "v6",
            server: "2001:db8::1",
            port: 443,
            cipher: "aes-128-gcm",
            password: "pw",
        )
        #expect(ShadowsocksURIEncoder.encode(server).contains("@[2001:db8::1]:443"))
        try expectRoundTrips(server)
    }

    @Test
    func `round-trips password containing @ and colon`() throws {
        try expectRoundTrips(ShadowsocksServer(
            name: "tricky",
            server: "1.2.3.4",
            port: 8388,
            cipher: "aes-256-gcm",
            password: "p@ss:word",
        ))
    }

    @Test
    func `encodes ech-tls-tunnel plugin options in order with bare flags`() throws {
        let server = ShadowsocksServer(
            name: "ech-sgp",
            server: "sgp.example.com",
            port: 443,
            cipher: "aes-128-gcm",
            password: "pw",
            plugin: ShadowsocksServer.echTLSPlugin,
            pluginOpts: [
                .init("mode", "client"),
                .init("sni", "sgp.example.com"),
                .init("path", "/ws-abc"),
                .init("ech_config", "QUJDRA=="),
                .init("fingerprint", "chrome"),
                .init("fast_open", "true"),
            ],
        )
        let uri = ShadowsocksURIEncoder.encode(server)
        // Fully percent-encoded SIP003 value: `;` → %3B, `=` → %3D.
        #expect(uri.contains("plugin=ech-tls-tunnel%3Bmode%3Dclient%3Bsni%3D"))
        // Boolean true is a bare flag, so no `fast_open=true`.
        #expect(uri.contains("%3Bfast_open#"))
        try expectRoundTrips(server)
    }

    @Test
    func `spells the engine's obfs plugin as obfs-local in share links`() throws {
        let server = ShadowsocksServer(
            name: "obfs",
            server: "obfs.example.com",
            port: 8388,
            cipher: "aes-256-gcm",
            password: "pw",
            plugin: ShadowsocksServer.obfsPlugin,
            pluginOpts: [
                .init("mode", "http"),
                .init("host", "www.bing.com"),
            ],
        )
        let uri = ShadowsocksURIEncoder.encode(server)
        #expect(uri.contains("obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dwww.bing.com"))
        // The parser canonicalizes obfs-local back to the engine spelling.
        try expectRoundTrips(server)
    }

    @Test
    func `round-trips v2ray-plugin with boolean flags`() throws {
        try expectRoundTrips(ShadowsocksServer(
            name: "ws",
            server: "ws.example.com",
            port: 443,
            cipher: "chacha20-ietf-poly1305",
            password: "pw",
            plugin: ShadowsocksServer.v2rayPlugin,
            pluginOpts: [
                .init("mode", "websocket"),
                .init("tls", "true"),
                .init("host", "cdn.example.com"),
                .init("path", "/ws"),
                .init("mux", "true"),
            ],
        ))
    }

    @Test
    func `percent-encodes non-ASCII names`() throws {
        let server = ShadowsocksServer(
            name: "香港 01",
            server: "hk.example.com",
            port: 443,
            cipher: "aes-128-gcm",
            password: "pw",
        )
        let uri = ShadowsocksURIEncoder.encode(server)
        #expect(!uri.contains("香港"))
        try expectRoundTrips(server)
    }

    @Test
    func `omits the fragment for empty names`() {
        let server = ShadowsocksServer(
            name: "",
            server: "example.com",
            port: 443,
            cipher: "aes-128-gcm",
            password: "pw",
        )
        #expect(!ShadowsocksURIEncoder.encode(server).contains("#"))
    }
}
