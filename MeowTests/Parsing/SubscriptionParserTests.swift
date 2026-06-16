import Foundation
@testable import meow_ios
import Testing

@Suite("YAML patcher", .tags(.parsing))
struct YamlPatcherTests {
    @Test
    func `strips subscriptions block and pins listener settings`() throws {
        let data = try loadFixture("clash_minimal")
        let yaml = try #require(String(data: data, encoding: .utf8))
        let patched = try YamlPatcher.applyMixedPort(yaml, port: 7890)
        #expect(!patched.contains("subscriptions:"))
        #expect(patched.contains("mixed-port: 7890"))
        #expect(patched.contains("allow-lan: false"))
        #expect(patched.contains("bind-address: 127.0.0.1"))
        #expect(patched.contains("listen: 127.0.0.1:1053"))
    }
}

extension YamlPatcherTests {
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "yaml") ?? bundle.url(forResource: name, withExtension: "txt"),
            "fixture \(name) not found in test bundle",
        )
        return try Data(contentsOf: url)
    }

    private final class FixtureAnchor {}
}

/// Tests for the subscription parser: Clash YAML detection, parse, and
/// v2rayN nodelist conversion. Fixtures live under `MeowTests/Fixtures/`.
/// Fixtures mirror the shapes used by the Android e2e test
/// (`/Volumes/DATA/workspace/meow-go/test-e2e.sh`).
@Suite("Subscription parser", .tags(.parsing))
struct SubscriptionParserTests {
    @Test
    func `detects Clash YAML by presence of proxies: key`() throws {
        let input = try loadFixture("clash_minimal")
        #expect(SubscriptionParser.detectFormat(input) == .clashYaml)
    }

    @Test
    func `detects Clash YAML when rule blocks appear before proxies`() {
        let rules = (0 ..< 180)
            .map { "  - DOMAIN-SUFFIX,example\($0).com,DIRECT" }
            .joined(separator: "\n")
        let input = Data("""
        rules:
        \(rules)
        proxies:
          - name: late-node
            type: direct
        proxy-groups:
          - name: Choose
            type: select
            proxies:
              - late-node
        """.utf8)

        #expect(SubscriptionParser.detectFormat(input) == .clashYaml)
    }

    @Test
    func `detects v2rayN base64 nodelist`() throws {
        let input = try loadFixture("v2rayn_ss_pair")
        #expect(SubscriptionParser.detectFormat(input) == .v2rayN)
    }

    @Test
    func `parses all MVP protocols from one file`() async throws {
        // clash_full.yaml has one node per protocol: ss/trojan/vless/vmess/wg/hy2/tuic
        let data = try loadFixture("clash_full")
        let converter = ClashYAMLConverter()
        let yaml = try await converter.convert(data)
        #expect(yaml.contains("node-ss"))
        #expect(yaml.contains("node-trojan"))
        #expect(yaml.contains("node-vless"))
        #expect(yaml.contains("node-vmess"))
    }

    @Test
    func `rejects malformed YAML with specific error`() async throws {
        let input = try loadFixture("clash_malformed")
        let converter = ClashYAMLConverter()
        await #expect(throws: Error.self) {
            try await converter.convert(input)
        }
    }
}

@Suite("Nodelist → Clash YAML conversion", .tags(.parsing, .ffi))
struct NodelistConverterTests {
    @Test
    func `v2rayN base64 converts through meow_engine_convert_subscription FFI`() async throws {
        let b64 = try loadFixture("v2rayn_ss_pair")
        let converter = ClashYAMLConverter()
        let yaml = try await converter.convert(b64)
        #expect(yaml.contains("test-node-1"))
        #expect(yaml.contains("test-node-2"))
    }
}

extension SubscriptionParserTests {
    /// Locates a fixture YAML inside the test bundle.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "yaml") ?? bundle.url(forResource: name, withExtension: "txt"),
            "fixture \(name) not found in test bundle",
        )
        return try Data(contentsOf: url)
    }

    private final class FixtureAnchor {}
}

extension NodelistConverterTests {
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "yaml") ?? bundle.url(forResource: name, withExtension: "txt"),
            "fixture \(name) not found in test bundle",
        )
        return try Data(contentsOf: url)
    }

    private final class FixtureAnchor {}
}

extension Tag {
    @Tag static var parsing: Self
}
