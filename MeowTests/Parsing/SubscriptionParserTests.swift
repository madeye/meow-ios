import Testing
import Foundation

/// Tests for the subscription parser: Clash YAML detection, parse, and
/// v2rayN nodelist conversion. Fixtures live under `MeowTests/Fixtures/`.
/// Fixtures mirror the shapes used by the Android e2e test
/// (`/Volumes/DATA/workspace/meow-go/test-e2e.sh`).
@Suite("Subscription parser", .tags(.parsing))
struct SubscriptionParserTests {

    @Test("detects Clash YAML by presence of proxies: key", .disabled("blocked on SubscriptionParser implementation"))
    func testDetectClash() {
        // let input = loadFixture("yaml/clash_minimal.yaml")
        // #expect(SubscriptionParser.detectFormat(input) == .clashYaml)
    }

    @Test("detects v2rayN base64 nodelist", .disabled("blocked on SubscriptionParser"))
    func testDetectNodelist() {
        // let input = loadFixture("nodelist/v2rayn_ss_pair.txt")
        // #expect(SubscriptionParser.detectFormat(input) == .v2rayN)
    }

    @Test("parses all MVP protocols from one file", .disabled("blocked on SubscriptionParser"))
    func testParseAllProtocols() {
        // clash_full.yaml has one node per protocol: ss/trojan/vless/vmess/wg/hy2/tuic
        // #expect(parsed.proxies.count == 7)
        // #expect(Set(parsed.proxies.map(\.type)) == [.ss, .trojan, .vless, .vmess, .wireguard, .hysteria2, .tuic])
    }

    @Test("rejects malformed YAML with specific error", .disabled("blocked on SubscriptionParser"))
    func testMalformedRejection() {
        // let input = loadFixture("yaml/clash_malformed.yaml")
        // expect throws ParseError.malformedYaml
    }

    @Test("empty proxies array yields specific error", .disabled("blocked on SubscriptionParser"))
    func testEmptyProxiesError() {
        // expect throws ParseError.noProxies
    }
}

@Suite("Nodelist → Clash YAML conversion", .tags(.parsing, .ffi))
struct NodelistConverterTests {

    @Test("v2rayN base64 converts through meow_engine_convert_subscription FFI", .disabled("blocked on T2.4"))
    func testConvertsViaFfi() {
        // let b64 = loadFixture("nodelist/v2rayn_ss_pair.txt")
        // let yaml = NodelistConverter.convert(b64)
        // #expect(yaml.contains("test-node-1"))
        // #expect(yaml.contains("test-node-2"))
    }
}

@Suite("YAML patcher", .tags(.parsing))
struct YamlPatcherTests {

    @Test("strips subscriptions block and sets mixed-port", .disabled("blocked on YamlPatcher"))
    func testStripSubscriptionsSetPort() {
        // patched = YamlPatcher.applyMixedPort(clash_with_subs, port: 7890)
        // #expect(!patched.contains("subscriptions:"))
        // #expect(patched.contains("mixed-port: 7890"))
    }

    @Test("revert restores the pre-edit backup", .disabled("blocked on YamlPatcher"))
    func testRevertRestoresBackup() {
        // roundtrip through patch → backup → revert
    }
}

extension Tag {
    @Tag static var parsing: Self
}
