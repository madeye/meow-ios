import Foundation

/// A single Clash rule rendered as a structured value for the in-app
/// editor. Parsed from / serialized to its on-wire string form via
/// [`rawLine`].
///
/// Meow rule lines come in three shapes:
///
///   - `MATCH,PROXY`                  — the final fallback (type=MATCH)
///   - `TYPE,PAYLOAD,PROXY`           — the common case
///   - `TYPE,PAYLOAD,PROXY,FLAG[,…]`  — IP-family rules with `no-resolve`,
///                                      `src`, …
///
/// `flags` preserves the trailing-flag section verbatim so round-tripping
/// a rule we don't recognise (a new flag meow adds upstream) is lossless.
struct EditableRule: Identifiable, Equatable, Hashable {
    /// Stable identity for SwiftUI list mutation. Decoupled from the
    /// rule's textual content so renaming a payload doesn't re-issue the
    /// row identity (otherwise focus / animation churn during typing).
    let id: UUID
    var type: String
    var payload: String
    var proxy: String
    var flags: [String]

    init(id: UUID = UUID(), type: String, payload: String, proxy: String, flags: [String] = []) {
        self.id = id
        self.type = type
        self.payload = payload
        self.proxy = proxy
        self.flags = flags
    }

    /// Parse a single rule line. Returns `nil` if the line has too few
    /// fields to be a valid Clash rule (callers skip such lines during
    /// load rather than producing a partially-initialised row that the
    /// user might accidentally save back).
    init?(rawLine: String) {
        // Meow trims whitespace around each comma-separated field; mirror
        // that here so a YAML rule written `"DOMAIN-SUFFIX , x.com , DIRECT"`
        // round-trips into the canonical compact form.
        let parts = rawLine.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }

        let type = parts[0].uppercased()
        if type == "MATCH" {
            // MATCH has no payload; second field is the proxy.
            self.init(type: type, payload: "", proxy: parts[1], flags: [])
            return
        }

        // Generic shape: TYPE,PAYLOAD,PROXY[,FLAG…]
        guard parts.count >= 3 else { return nil }
        let payload = parts[1]
        let proxy = parts[2]
        let flags = parts.count > 3 ? Array(parts[3...]) : []
        self.init(type: type, payload: payload, proxy: proxy, flags: flags)
    }

    /// Serialise back to the on-wire string. Trailing flags are emitted in
    /// the same order they were parsed, and MATCH rules collapse to the
    /// two-field form.
    var rawLine: String {
        if type.uppercased() == "MATCH" {
            return "MATCH,\(proxy)"
        }
        var parts = [type, payload, proxy]
        parts.append(contentsOf: flags)
        return parts.joined(separator: ",")
    }
}

/// Canonical Clash rule types surfaced in the editor's type picker. The
/// list is an editorial subset — meow accepts more (`AND`, `OR`, `NOT`,
/// `SUB-RULE`, …) but those nest other rules and don't fit the single-line
/// editor model; users authoring them stay on the raw YAML editor instead.
///
/// `RULE-SET` is included for completeness even though it points at a
/// rule-provider — editing the payload is still useful (renaming a
/// provider) and the engine performs the same expansion regardless of how
/// the line was authored.
enum EditableRuleType: String, CaseIterable, Identifiable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case geoip = "GEOIP"
    case srcIPCIDR = "SRC-IP-CIDR"
    case dstPort = "DST-PORT"
    case srcPort = "SRC-PORT"
    case processName = "PROCESS-NAME"
    case ruleSet = "RULE-SET"
    case match = "MATCH"

    var id: String {
        rawValue
    }

    /// Whether this rule type takes a payload field. MATCH does not; every
    /// other type does.
    var takesPayload: Bool {
        self != .match
    }

    /// Whether this rule type accepts the `no-resolve` flag. Meow
    /// rejects `no-resolve` on domain-family rules (it's only meaningful
    /// for IP-family rules where deciding requires a DNS resolve first).
    var supportsNoResolve: Bool {
        switch self {
        case .ipCIDR, .ipCIDR6, .geoip, .srcIPCIDR: true
        default: false
        }
    }
}
