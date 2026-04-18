import Foundation

// PRD §4.4 "Diagnostics Surface Contract" — stable, glanceable text
// format rendered by the Debug Diagnostics Panel (T2.6) for the manual
// on-device smoke (PROJECT_PLAN T2.8).
//
// This file is the single source of truth. Renaming any case here
// breaks the build (panel UIViewController + XCUITest assertions both
// reference the typed enum, not literal strings), which is the point.

/// Fixed ASCII label keys. Display order equals declaration order and
/// must match the PRD §4.4 table.
public enum DiagnosticsCheck: String, CaseIterable, Sendable {
    case tunExists = "TUN_EXISTS"
    case dnsOk = "DNS_OK"
    case tcpProxyOk = "TCP_PROXY_OK"
    case http204Ok = "HTTP_204_OK"
    case memOk = "MEM_OK"
}

/// Parsed result of one diagnostics row.
public enum DiagnosticsResult: Equatable, Sendable {
    case pass
    case fail(reason: String)
}

/// Parser for the PRD §4.4 label format:
///
///     CHECK_NAME: PASS
///     CHECK_NAME: FAIL(<reason>)
///
/// Contract (from PRD §4.4):
/// - `CHECK_NAME:` is a fixed ASCII string, no localisation, no emoji
/// - separator is always ASCII colon + space
/// - `PASS` is always the literal 4-character uppercase string
/// - `FAIL(` is the literal 5-character prefix, `)` closes it
public enum DiagnosticsLabelParser {
    public enum ParseError: Error, Equatable, Sendable {
        case malformed(line: String)
        case unknownKey(String)
        case duplicateKey(DiagnosticsCheck)
        case missingKeys([DiagnosticsCheck])
    }

    /// Parse a complete diagnostics panel text dump. Fails closed on any
    /// malformed row, unknown key, duplicate key, or missing key — so a
    /// partial panel output can't silently appear to pass.
    public static func parse(_ text: String) throws -> [DiagnosticsCheck: DiagnosticsResult] {
        var out: [DiagnosticsCheck: DiagnosticsResult] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            guard let colon = line.range(of: ": ") else {
                throw ParseError.malformed(line: line)
            }
            let keyStr = String(line[..<colon.lowerBound])
            let valueStr = String(line[colon.upperBound...])

            guard let key = DiagnosticsCheck(rawValue: keyStr) else {
                throw ParseError.unknownKey(keyStr)
            }
            guard out[key] == nil else {
                throw ParseError.duplicateKey(key)
            }

            if valueStr == "PASS" {
                out[key] = .pass
            } else if valueStr.hasPrefix("FAIL("), valueStr.hasSuffix(")") {
                let reason = String(valueStr.dropFirst("FAIL(".count).dropLast())
                out[key] = .fail(reason: reason)
            } else {
                throw ParseError.malformed(line: line)
            }
        }

        let missing = DiagnosticsCheck.allCases.filter { out[$0] == nil }
        if !missing.isEmpty { throw ParseError.missingKeys(missing) }
        return out
    }

    /// Render a complete set of results in the PRD §4.4 canonical form.
    /// Used by the panel's `UIViewController` (T2.6) and by fixtures in
    /// unit tests.
    public static func render(_ results: [DiagnosticsCheck: DiagnosticsResult]) -> String {
        DiagnosticsCheck.allCases.map { check in
            let value = switch results[check] ?? .fail(reason: "missing") {
            case .pass: "PASS"
            case let .fail(reason): "FAIL(\(reason))"
            }
            return "\(check.rawValue): \(value)"
        }.joined(separator: "\n")
    }
}
