import Foundation
import Yams

struct LintDiagnostic {
    let line: Int
    let message: String
}

enum ClashConfigLinter {
    static func lint(_ yaml: String) -> [LintDiagnostic] {
        guard let node = try? Yams.compose(yaml: yaml) else {
            return []
        }
        guard let root = node.mapping else { return [] }
        var diags: [LintDiagnostic] = []
        checkScalarTypos(node, into: &diags)
        checkProxies(root, into: &diags)
        checkProxyGroups(root, into: &diags)
        checkRules(root, into: &diags)
        return diags
    }

    // MARK: - Boolean typo detection (recursive)

    private static let validBools: Set<String> = [
        "true", "false", "yes", "no",
        "True", "False", "Yes", "No",
        "TRUE", "FALSE", "YES", "NO",
        "on", "off", "On", "Off", "ON", "OFF",
    ]

    private static let boolLike: Set<String> = [
        "tru", "ture", "treu", "trie", "reu",
        "fals", "flase", "fasle", "fale",
        "ye", "ys", "yse",
        "non", "noo",
    ]

    private static let knownBoolKeys: Set<String> = [
        "allow-lan", "ipv6", "geodata-mode",
        "enable", "store-fake-ip", "store-selected",
        "use-hosts", "use-system-hosts",
        "sniffing", "force-dns-mapping",
        "parse-pure-ip", "override-destination",
        "skip-cert-verify", "udp", "tls", "xudp",
    ]

    private static let knownIntKeys: Set<String> = [
        "port", "socks-port", "redir-port", "tproxy-port", "mixed-port",
        "keep-alive-interval", "keep-alive-idle",
        "interval", "tolerance", "timeout",
        "mtu", "up", "down",
        "recv-window-conn", "recv-window",
    ]

    private static func checkScalarTypos(
        _ node: Node,
        into diags: inout [LintDiagnostic],
    ) {
        guard let mapping = node.mapping else { return }
        for (keyNode, valNode) in mapping {
            if let scalar = valNode.scalar {
                let val = scalar.string
                let key = keyNode.scalar?.string ?? ""
                let line = valNode.mark?.line ?? 0
                if knownBoolKeys.contains(key), !validBools.contains(val) {
                    diags.append(LintDiagnostic(
                        line: line,
                        message: "'\(key)' expects true/false, got '\(val)'",
                    ))
                } else if boolLike.contains(val.lowercased()) {
                    diags.append(LintDiagnostic(
                        line: line,
                        message: "'\(val)' looks like a typo for true/false",
                    ))
                }
                if knownIntKeys.contains(key),
                   !val.isEmpty,
                   Int(val) == nil
                {
                    diags.append(LintDiagnostic(
                        line: line,
                        message: "'\(key)' expects an integer, got '\(val)'",
                    ))
                }
            }
            if valNode.mapping != nil {
                checkScalarTypos(valNode, into: &diags)
            }
            if let seq = valNode.sequence {
                for child in seq where child.mapping != nil {
                    checkScalarTypos(child, into: &diags)
                }
            }
        }
    }

    // MARK: - Proxy checks

    private static let validProxyTypes: Set<String> = [
        "ss", "trojan", "vless", "vmess", "socks5", "http",
        "wireguard", "tuic", "hysteria", "hysteria2",
        "ssh", "snell", "direct", "reject",
    ]

    private static func checkProxies(
        _ root: Node.Mapping,
        into diags: inout [LintDiagnostic],
    ) {
        guard let seq = root[Node("proxies")]?.sequence else { return }
        for entry in seq {
            guard let m = entry.mapping else { continue }
            let line = entry.mark?.line ?? 0
            guard let typeNode = m[Node("type")] else {
                diags.append(LintDiagnostic(
                    line: line,
                    message: "proxy missing required field 'type'",
                ))
                continue
            }
            if let typeStr = typeNode.scalar?.string,
               !validProxyTypes.contains(typeStr)
            {
                diags.append(LintDiagnostic(
                    line: typeNode.mark?.line ?? line,
                    message: "unknown proxy type '\(typeStr)'",
                ))
            }
            checkProxyFields(m, line: line, into: &diags)
        }
    }

    private static func checkProxyFields(
        _ m: Node.Mapping,
        line: Int,
        into diags: inout [LintDiagnostic],
    ) {
        let typeStr = m[Node("type")]?.scalar?.string ?? ""
        let needsServer: Set = [
            "ss", "trojan", "vless", "vmess", "socks5", "http",
            "tuic", "hysteria", "hysteria2", "snell",
        ]
        if needsServer.contains(typeStr) {
            if m[Node("server")] == nil {
                diags.append(LintDiagnostic(
                    line: line,
                    message: "proxy type '\(typeStr)' requires 'server'",
                ))
            }
            if m[Node("port")] == nil {
                diags.append(LintDiagnostic(
                    line: line,
                    message: "proxy type '\(typeStr)' requires 'port'",
                ))
            }
        }
    }

    // MARK: - Proxy-group checks

    private static let validGroupTypes: Set<String> = [
        "select", "url-test", "fallback", "load-balance", "relay",
    ]

    private static func checkProxyGroups(
        _ root: Node.Mapping,
        into diags: inout [LintDiagnostic],
    ) {
        guard let seq = root[Node("proxy-groups")]?.sequence else { return }
        for entry in seq {
            guard let m = entry.mapping else { continue }
            let line = entry.mark?.line ?? 0
            guard let typeNode = m[Node("type")] else {
                diags.append(LintDiagnostic(
                    line: line,
                    message: "proxy-group missing required field 'type'",
                ))
                continue
            }
            if let typeStr = typeNode.scalar?.string,
               !validGroupTypes.contains(typeStr)
            {
                diags.append(LintDiagnostic(
                    line: typeNode.mark?.line ?? line,
                    message: "unknown proxy-group type '\(typeStr)'",
                ))
            }
            if m[Node("name")] == nil {
                diags.append(LintDiagnostic(
                    line: line,
                    message: "proxy-group missing required field 'name'",
                ))
            }
        }
    }

    // MARK: - Rule checks

    private static let validRuleTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD",
        "GEOIP", "GEOSITE", "IP-CIDR", "IP-CIDR6",
        "SRC-IP-CIDR", "SRC-PORT", "DST-PORT",
        "PROCESS-NAME", "PROCESS-PATH",
        "RULE-SET", "MATCH", "DIRECT", "REJECT",
    ]

    private static func checkRules(
        _ root: Node.Mapping,
        into diags: inout [LintDiagnostic],
    ) {
        guard let seq = root[Node("rules")]?.sequence else { return }
        for entry in seq {
            guard let scalar = entry.scalar else { continue }
            let line = entry.mark?.line ?? 0
            let parts = scalar.string.split(separator: ",", maxSplits: 2)
            guard let ruleType = parts.first else { continue }
            if !validRuleTypes.contains(String(ruleType)) {
                diags.append(LintDiagnostic(
                    line: line,
                    message: "unknown rule type '\(ruleType)'",
                ))
            }
        }
    }
}
