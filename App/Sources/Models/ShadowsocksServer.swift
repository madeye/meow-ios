import Foundation

/// A single Shadowsocks server, mirroring the field set of a Clash `type: ss`
/// proxy entry plus the optional SIP003 plugin block (e.g. the engine's
/// built-in `ech-tls-tunnel` client transport).
struct ShadowsocksServer: Equatable {
    /// One SIP003 plugin option. Kept as an ordered list (not a dictionary)
    /// so `plugin-opts` round-trips in a stable order.
    struct PluginOption: Equatable {
        var key: String
        var value: String

        init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    var name: String
    var server: String
    var port: Int
    var cipher: String
    var password: String
    var udp: Bool
    var plugin: String?
    var pluginOpts: [PluginOption]

    init(
        name: String,
        server: String,
        port: Int,
        cipher: String,
        password: String,
        udp: Bool = false,
        plugin: String? = nil,
        pluginOpts: [PluginOption] = [],
    ) {
        self.name = name
        self.server = server
        self.port = port
        self.cipher = cipher
        self.password = password
        self.udp = udp
        self.plugin = plugin
        self.pluginOpts = pluginOpts
    }

    /// Fallback display name, matching the engine-side subscription
    /// converter's convention (`ss-<host>-<port>`).
    static func defaultName(server: String, port: Int) -> String {
        "ss-\(server)-\(port)"
    }

    func pluginOption(_ key: String) -> String? {
        pluginOpts.first { $0.key == key }?.value
    }
}

extension ShadowsocksServer {
    /// AEAD ciphers offered by the manual-entry picker. Link/QR imports pass
    /// through whatever cipher the URI names, even if it isn't listed here.
    static let commonCiphers = [
        "aes-128-gcm",
        "aes-192-gcm",
        "aes-256-gcm",
        "chacha20-ietf-poly1305",
        "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305",
    ]

    static let defaultCipher = "aes-128-gcm"

    /// SIP003 plugin name of the engine's built-in ECH-TLS client transport.
    static let echTLSPlugin = "ech-tls-tunnel"

    /// Canonical Clash plugin name for simple-obfs (engine also accepts
    /// "simple-obfs"; SIP003's "obfs-local" is canonicalized to this).
    static let obfsPlugin = "obfs"

    /// Plugin name of the engine's built-in v2ray-plugin websocket transport.
    static let v2rayPlugin = "v2ray-plugin"
}
