import Foundation

/// Parses `ss://` share links (manual paste or QR scan) into
/// ``ShadowsocksServer`` values.
///
/// Supported shapes:
/// - SIP002: `ss://BASE64URL(method:password)@host:port/?plugin=…#name`
/// - SIP002 plain userinfo (SS-2022): `ss://method:password@host:port#name`
/// - Legacy: `ss://BASE64(method:password@host:port)#name`
///
/// The `plugin` query parameter is decoded as a SIP003 option string
/// (`name;key=value;flag`) so ECH-TLS tunnel QR codes round-trip.
enum ShadowsocksURIParser {
    enum ParseError: Error, Equatable {
        case notShadowsocks
        case malformed(String)
    }

    static func parse(_ raw: String) throws -> ShadowsocksServer {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ss://") else {
            throw ParseError.notShadowsocks
        }
        let body = String(trimmed.dropFirst("ss://".count))
        let beforeFragment = body.prefix { $0 != "#" }
        if beforeFragment.contains("@") {
            return try parseSIP002(trimmed)
        }
        return try parseLegacy(body)
    }

    // MARK: - SIP002

    private static func parseSIP002(_ uri: String) throws -> ShadowsocksServer {
        guard let comps = URLComponents(string: uri), var host = comps.host, !host.isEmpty else {
            throw ParseError.malformed("unparseable SIP002 URI")
        }
        // Foundation keeps the brackets of an IPv6 literal in `host`; Clash
        // YAML wants the bare address.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard let port = comps.port, (1 ... 65535).contains(port) else {
            throw ParseError.malformed("missing or invalid port")
        }

        let method: String
        let password: String
        if let plainPassword = comps.password, let user = comps.user {
            // Plain `method:password` userinfo (percent-encoded) — used by
            // SS-2022 ciphers. URLComponents already split at the first ':'.
            method = user
            password = plainPassword
        } else if let user = comps.user,
                  let decoded = decodeBase64(String(user)),
                  let colon = decoded.firstIndex(of: ":")
        {
            method = String(decoded[..<colon])
            password = String(decoded[decoded.index(after: colon)...])
        } else {
            throw ParseError.malformed("userinfo is neither base64 nor method:password")
        }
        guard !method.isEmpty else { throw ParseError.malformed("empty cipher") }

        var plugin: String?
        var opts: [ShadowsocksServer.PluginOption] = []
        if let pluginValue = comps.queryItems?.first(where: { $0.name == "plugin" })?.value,
           !pluginValue.isEmpty
        {
            (plugin, opts) = parseSIP003(pluginValue)
        }

        let name = comps.fragment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShadowsocksServer(
            name: name.isEmpty ? ShadowsocksServer.defaultName(server: host, port: port) : name,
            server: host,
            port: port,
            cipher: method,
            password: password,
            plugin: plugin,
            pluginOpts: opts,
        )
    }

    /// Splits a SIP003 plugin string (`name;key=value;flag`) into the plugin
    /// name and its options. Bare flags decode as `true`.
    private static func parseSIP003(_ value: String) -> (String, [ShadowsocksServer.PluginOption]) {
        var parts = value.components(separatedBy: ";")
        let name = parts.removeFirst()
        var opts: [ShadowsocksServer.PluginOption] = []
        for part in parts where !part.isEmpty {
            if let eq = part.firstIndex(of: "=") {
                opts.append(.init(String(part[..<eq]), String(part[part.index(after: eq)...])))
            } else {
                opts.append(.init(part, "true"))
            }
        }
        return canonicalizePlugin(name, opts)
    }

    /// Maps SIP003 spellings onto the Clash plugin names/opt keys the engine
    /// dispatches on. Share links name simple-obfs's client binary
    /// ("obfs-local") — left as-is the engine would treat it as an external
    /// subprocess plugin, which can't exist on iOS.
    private static func canonicalizePlugin(
        _ name: String,
        _ opts: [ShadowsocksServer.PluginOption],
    ) -> (String, [ShadowsocksServer.PluginOption]) {
        switch name {
        case "obfs-local", "simple-obfs", ShadowsocksServer.obfsPlugin:
            let mapped = opts.map { opt in
                switch opt.key {
                case "obfs": ShadowsocksServer.PluginOption("mode", opt.value)
                case "obfs-host": ShadowsocksServer.PluginOption("host", opt.value)
                default: opt
                }
            }
            return (ShadowsocksServer.obfsPlugin, mapped)
        default:
            return (name, opts)
        }
    }

    // MARK: - Legacy (whole-body base64)

    private static func parseLegacy(_ body: String) throws -> ShadowsocksServer {
        var rest = body
        var name = ""
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding ?? ""
            rest = String(rest[..<hash])
        }
        if let query = rest.firstIndex(of: "?") {
            rest = String(rest[..<query])
        }
        while rest.hasSuffix("/") {
            rest.removeLast()
        }
        guard let decoded = decodeBase64(rest) else {
            throw ParseError.malformed("invalid base64 payload")
        }
        // method:password@host:port — password may itself contain '@' or ':',
        // so split at the LAST '@' and the FIRST ':' of the userinfo.
        guard let at = decoded.range(of: "@", options: .backwards) else {
            throw ParseError.malformed("missing @ separator")
        }
        let userinfo = String(decoded[..<at.lowerBound])
        let hostPort = String(decoded[at.upperBound...])
        guard let colon = userinfo.firstIndex(of: ":") else {
            throw ParseError.malformed("missing method:password separator")
        }
        let method = String(userinfo[..<colon])
        let password = String(userinfo[userinfo.index(after: colon)...])
        guard !method.isEmpty else { throw ParseError.malformed("empty cipher") }
        let (host, port) = try parseHostPort(hostPort)
        return ShadowsocksServer(
            name: name.isEmpty ? ShadowsocksServer.defaultName(server: host, port: port) : name,
            server: host,
            port: port,
            cipher: method,
            password: password,
        )
    }

    private static func parseHostPort(_ hostPort: String) throws -> (String, Int) {
        let host: String
        let portText: String
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else {
                throw ParseError.malformed("unterminated IPv6 literal")
            }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex) ..< close])
            let after = hostPort[hostPort.index(after: close)...]
            guard after.hasPrefix(":") else {
                throw ParseError.malformed("missing port")
            }
            portText = String(after.dropFirst())
        } else {
            guard let colon = hostPort.range(of: ":", options: .backwards) else {
                throw ParseError.malformed("missing port")
            }
            host = String(hostPort[..<colon.lowerBound])
            portText = String(hostPort[colon.upperBound...])
        }
        guard !host.isEmpty else { throw ParseError.malformed("empty host") }
        guard let port = Int(portText), (1 ... 65535).contains(port) else {
            throw ParseError.malformed("invalid port")
        }
        return (host, port)
    }

    /// Decodes standard or URL-safe base64, tolerating missing padding.
    private static func decodeBase64(_ text: String) -> String? {
        var b64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64.removeAll(where: \.isWhitespace)
        while b64.count % 4 != 0 {
            b64.append("=")
        }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
