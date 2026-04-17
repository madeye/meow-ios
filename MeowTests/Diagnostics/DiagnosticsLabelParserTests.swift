import Testing
import MeowModels

/// Unit tests for the PRD §4.4 Diagnostics Surface Contract parser.
///
/// The parser (`DiagnosticsLabelParser` in `MeowUITests/Support/VPhone.swift`)
/// is the only consumer of the OCR'd panel output. These tests lock in
/// the label grammar so that a sloppy Dev change to the panel's
/// rendering code (e.g. inserting emoji, localising "PASS", reordering
/// rows) fails the parser before it reaches the nightly gate.
@Suite("PRD §4.4 diagnostics label parser")
struct DiagnosticsLabelParserTests {

    @Test("accepts all-PASS in canonical order")
    func allPassCanonical() throws {
        let input = """
        TUN_EXISTS: PASS
        DNS_OK: PASS
        TCP_PROXY_OK: PASS
        HTTP_204_OK: PASS
        MEM_OK: PASS
        """
        let results = try DiagnosticsLabelParser.parse(input)
        #expect(results.count == DiagnosticsCheck.allCases.count)
        for check in DiagnosticsCheck.allCases {
            #expect(results[check] == .pass)
        }
    }

    @Test("parses FAIL(<reason>) with ASCII reason")
    func failWithReason() throws {
        let input = """
        TUN_EXISTS: PASS
        DNS_OK: FAIL(timeout)
        TCP_PROXY_OK: FAIL(refused)
        HTTP_204_OK: FAIL(status=500)
        MEM_OK: FAIL(mem=17mb>=15mb)
        """
        let results = try DiagnosticsLabelParser.parse(input)
        #expect(results[.tunExists] == .pass)
        #expect(results[.dnsOk] == .fail(reason: "timeout"))
        #expect(results[.tcpProxyOk] == .fail(reason: "refused"))
        #expect(results[.http204Ok] == .fail(reason: "status=500"))
        #expect(results[.memOk] == .fail(reason: "mem=17mb>=15mb"))
    }

    @Test("rejects missing keys — gate must not pass on partial output")
    func missingKeyFails() {
        let input = """
        TUN_EXISTS: PASS
        DNS_OK: PASS
        TCP_PROXY_OK: PASS
        HTTP_204_OK: PASS
        """
        #expect(throws: DiagnosticsLabelParser.ParseError.self) {
            try DiagnosticsLabelParser.parse(input)
        }
    }

    @Test("rejects unknown key — Dev must not silently add a 6th row")
    func unknownKeyFails() {
        let input = """
        TUN_EXISTS: PASS
        DNS_OK: PASS
        TCP_PROXY_OK: PASS
        HTTP_204_OK: PASS
        MEM_OK: PASS
        RTT_OK: PASS
        """
        #expect(throws: DiagnosticsLabelParser.ParseError.self) {
            try DiagnosticsLabelParser.parse(input)
        }
    }

    @Test("rejects localised PASS — label must stay ASCII uppercase")
    func localisedPassFails() {
        let input = """
        TUN_EXISTS: Pass
        DNS_OK: PASS
        TCP_PROXY_OK: PASS
        HTTP_204_OK: PASS
        MEM_OK: PASS
        """
        #expect(throws: DiagnosticsLabelParser.ParseError.self) {
            try DiagnosticsLabelParser.parse(input)
        }
    }

    @Test("rejects emoji-adorned key — label prefix must be ASCII only")
    func emojiKeyFails() {
        let input = """
        ✅TUN_EXISTS: PASS
        DNS_OK: PASS
        TCP_PROXY_OK: PASS
        HTTP_204_OK: PASS
        MEM_OK: PASS
        """
        #expect(throws: DiagnosticsLabelParser.ParseError.self) {
            try DiagnosticsLabelParser.parse(input)
        }
    }

    @Test("rejects duplicate key")
    func duplicateKeyFails() {
        let input = """
        TUN_EXISTS: PASS
        TUN_EXISTS: FAIL(engine_not_running)
        DNS_OK: PASS
        TCP_PROXY_OK: PASS
        HTTP_204_OK: PASS
        MEM_OK: PASS
        """
        #expect(throws: DiagnosticsLabelParser.ParseError.self) {
            try DiagnosticsLabelParser.parse(input)
        }
    }

    @Test("tolerates trailing whitespace on a row")
    func trailingWhitespaceTolerated() throws {
        let input = "TUN_EXISTS: PASS   \nDNS_OK: PASS\nTCP_PROXY_OK: PASS\nHTTP_204_OK: PASS\nMEM_OK: PASS"
        let results = try DiagnosticsLabelParser.parse(input)
        #expect(results[.tunExists] == .pass)
    }
}
