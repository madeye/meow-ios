import Foundation

/// Renders a ``ShadowsocksServer`` back into a SIP002 `ss://` share link —
/// the inverse of ``ShadowsocksURIParser`` — so locally added servers can be
/// exported as QR codes.
///
/// Output shapes:
/// - SS-2022 ciphers (`2022-…`): plain percent-encoded `method:password`
///   userinfo, per SIP002's AEAD-2022 recommendation.
/// - Everything else: unpadded base64url `method:password` userinfo.
/// - Plugins are re-spelled in SIP003 form (`name;key=value;flag`), with the
///   engine's canonical names mapped back to the share-link spellings the
///   parser canonicalizes from (`obfs` → `obfs-local`).
///
/// The `udp` field has no SIP002 representation and is not exported.
enum ShadowsocksURIEncoder {
    static func encode(_ server: ShadowsocksServer) -> String {
        var uri = "ss://\(userinfo(server))@\(hostText(server.server)):\(server.port)"
        if let plugin = server.plugin, !plugin.isEmpty {
            let value = sip003Value(plugin, server.pluginOpts)
            uri += "/?plugin=\(percentEncode(value))"
        }
        if !server.name.isEmpty {
            uri += "#\(percentEncode(server.name))"
        }
        return uri
    }

    // MARK: - Components

    private static func userinfo(_ server: ShadowsocksServer) -> String {
        if server.cipher.hasPrefix("2022-") {
            return "\(percentEncode(server.cipher)):\(percentEncode(server.password))"
        }
        return base64URLNoPad("\(server.cipher):\(server.password)")
    }

    /// Clash YAML stores IPv6 literals bare; the URI authority needs brackets.
    private static func hostText(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    /// Joins plugin name and options into a SIP003 option string. Boolean
    /// `true` options are emitted as bare flags (`fast_open`), matching how
    /// the parser decodes them, so the pair round-trips.
    private static func sip003Value(
        _ plugin: String,
        _ opts: [ShadowsocksServer.PluginOption],
    ) -> String {
        let (name, mapped) = shareLinkPlugin(plugin, opts)
        var parts = [name]
        for opt in mapped {
            parts.append(opt.value == "true" ? opt.key : "\(opt.key)=\(opt.value)")
        }
        return parts.joined(separator: ";")
    }

    /// Inverse of the parser's `canonicalizePlugin`: the engine's `obfs`
    /// plugin is spelled `obfs-local` in share links, with `mode`/`host`
    /// spelled `obfs`/`obfs-host`.
    private static func shareLinkPlugin(
        _ plugin: String,
        _ opts: [ShadowsocksServer.PluginOption],
    ) -> (String, [ShadowsocksServer.PluginOption]) {
        guard plugin == ShadowsocksServer.obfsPlugin else { return (plugin, opts) }
        let mapped = opts.map { opt in
            switch opt.key {
            case "mode": ShadowsocksServer.PluginOption("obfs", opt.value)
            case "host": ShadowsocksServer.PluginOption("obfs-host", opt.value)
            default: opt
            }
        }
        return ("obfs-local", mapped)
    }

    // MARK: - Encoding helpers

    /// RFC 3986 unreserved characters — everything else is percent-encoded.
    /// Deliberately stricter than `urlQueryAllowed` so SIP003 separators
    /// (`;`, `=`) inside the plugin value can't be confused with URI syntax,
    /// matching the fully-encoded examples in the SIP002 spec.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static func base64URLNoPad(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
