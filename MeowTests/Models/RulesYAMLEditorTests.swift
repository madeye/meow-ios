import Foundation
@testable import meow_ios
import Testing
import Yams

@Suite("RulesYAMLEditor + EditableRule round-trip")
struct RulesYAMLEditorTests {
    @Test
    func `DOMAIN-SUFFIX parses + serialises identically`() throws {
        let rule = try #require(EditableRule(rawLine: "DOMAIN-SUFFIX,google.com,Proxy"))
        #expect(rule.type == "DOMAIN-SUFFIX")
        #expect(rule.payload == "google.com")
        #expect(rule.proxy == "Proxy")
        #expect(rule.flags.isEmpty)
        #expect(rule.rawLine == "DOMAIN-SUFFIX,google.com,Proxy")
    }

    @Test
    func `MATCH has no payload and collapses to two fields on emit`() throws {
        let rule = try #require(EditableRule(rawLine: "MATCH,DIRECT"))
        #expect(rule.type == "MATCH")
        #expect(rule.payload == "")
        #expect(rule.proxy == "DIRECT")
        #expect(rule.rawLine == "MATCH,DIRECT")
    }

    @Test
    func `Trailing no-resolve flag survives a round-trip on IP rules`() throws {
        let rule = try #require(EditableRule(rawLine: "IP-CIDR,1.1.1.1/32,DIRECT,no-resolve"))
        #expect(rule.flags == ["no-resolve"])
        #expect(rule.rawLine == "IP-CIDR,1.1.1.1/32,DIRECT,no-resolve")
    }

    @Test
    func `Whitespace around commas is folded into the canonical form`() throws {
        let rule = try #require(EditableRule(rawLine: " DOMAIN-SUFFIX , x.com , DIRECT "))
        #expect(rule.payload == "x.com")
        #expect(rule.rawLine == "DOMAIN-SUFFIX,x.com,DIRECT")
    }

    @Test
    func `Truncated lines (no proxy) parse as nil rather than half-built`() {
        // One field — not a rule at all.
        #expect(EditableRule(rawLine: "DOMAIN-SUFFIX") == nil)
        // Two fields but type is not MATCH → still missing proxy.
        #expect(EditableRule(rawLine: "DOMAIN-SUFFIX,google.com") == nil)
    }

    @Test
    func `RulesYAMLEditor.load extracts every rule line in order`() throws {
        let yaml = """
        mode: rule
        rules:
          - DOMAIN-SUFFIX,google.com,Proxy
          - IP-CIDR,1.1.1.1/32,DIRECT,no-resolve
          - MATCH,DIRECT
        """
        let rules = try RulesYAMLEditor.load(from: yaml)
        #expect(rules.count == 3)
        #expect(rules[0].type == "DOMAIN-SUFFIX")
        #expect(rules[1].flags == ["no-resolve"])
        #expect(rules[2].type == "MATCH")
    }

    @Test
    func `RulesYAMLEditor.apply rewrites only the rules block`() throws {
        let source = """
        mode: rule
        log-level: info
        rules:
          - DOMAIN-SUFFIX,google.com,Proxy
          - MATCH,DIRECT
        proxies:
          - name: P
            type: direct
        """
        let original = try RulesYAMLEditor.load(from: source)
        // Drop the DOMAIN-SUFFIX rule; keep MATCH.
        let edited = Array(original.suffix(1))
        let rewritten = try RulesYAMLEditor.apply(edited, to: source)

        // Round-trip via Yams to compare structurally — key order is not
        // load-bearing, and `apply` sortKeys-emits.
        let loaded = try Yams.load(yaml: rewritten) as? [String: Any]
        let m = try #require(loaded)
        #expect((m["mode"] as? String) == "rule")
        #expect((m["log-level"] as? String) == "info")
        #expect(m["proxies"] != nil, "proxies block must survive the edit")
        let lines = try #require(m["rules"] as? [String])
        #expect(lines == ["MATCH,DIRECT"])
    }

    @Test
    func `Empty YAML round-trips to no rules`() throws {
        let rules = try RulesYAMLEditor.load(from: "")
        #expect(rules.isEmpty)
    }

    @Test
    func `Missing rules block returns an empty list rather than failing`() throws {
        let rules = try RulesYAMLEditor.load(from: "mode: rule\n")
        #expect(rules.isEmpty)
    }

    @Test
    func `Non-string entries in rules: are silently dropped`() throws {
        // Defensive: if a future YAML ships an object-form rule shape we
        // can't parse as a single line, skip rather than crashing.
        let yaml = """
        rules:
          - DOMAIN-SUFFIX,a.com,Proxy
          - {weird: shape}
          - MATCH,DIRECT
        """
        let rules = try RulesYAMLEditor.load(from: yaml)
        #expect(rules.map(\.type) == ["DOMAIN-SUFFIX", "MATCH"])
    }
}
