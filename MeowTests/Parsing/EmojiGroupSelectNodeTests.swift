import Foundation
@testable import meow_ios
import Testing
import Yams

/// Real-world Clash YAML pulled from a third-party subscription
/// (sanitized: server IP, password, SNI, and the `#!MANAGED-CONFIG` URL
/// all replaced with TEST-NET / placeholder values; provider identifying
/// strings stripped). Verifies the shape the app's "select node" UX
/// depends on:
///
/// 1. The parser's sniff (`SubscriptionParser.looksLikeClashYAML`) accepts
///    the file.
/// 2. Yams can round-trip the file — emoji-named proxies/groups don't
///    confuse the YAML decoder.
/// 3. There is exactly one `type: select` group named `🚀 节点选择`, and
///    every name it lists either resolves to a proxy in the `proxies:`
///    block or is a built-in (`DIRECT`/`REJECT`). Dangling references are
///    the bug class that breaks the picker — once mihomo-rust converts
///    `select` → `Selector`, `ProxyGroupModel.build(from:)` would render
///    a child the user can't actually switch to.
@Suite("Emoji-named proxy groups · select-node", .tags(.parsing))
struct EmojiGroupSelectNodeTests {
    @Test
    func `node-select group has every child resolvable`() throws {
        let data = try Self.loadFixture("clash_emoji_groups_realworld")

        #expect(SubscriptionParser.looksLikeClashYAML(data))

        let text = try #require(String(data: data, encoding: .utf8))
        let root = try #require(try Yams.load(yaml: text) as? [String: Any])

        // Collect proxy names.
        let proxies = try #require(root["proxies"] as? [[String: Any]])
        let proxyNames = Set(proxies.compactMap { $0["name"] as? String })
        #expect(proxies.count == 32)

        // Find the select-node group.
        let groups = try #require(root["proxy-groups"] as? [[String: Any]])
        #expect(groups.count == 3)

        let selectNode = try #require(groups.first { ($0["name"] as? String) == "🚀 节点选择" })
        #expect(selectNode["type"] as? String == "select")

        let children = try #require(selectNode["proxies"] as? [String])
        #expect(children.count == 33)
        #expect(children.last == "DIRECT")

        // Every named child must resolve — either to a parsed proxy or to a
        // mihomo built-in. A drift here is what makes "select node" silently
        // surface a row the user can't actually switch to.
        let builtins = Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"])
        let unresolved = children.filter { !proxyNames.contains($0) && !builtins.contains($0) }
        #expect(unresolved.isEmpty, "select-node references unresolved children: \(unresolved)")

        // The two derived select groups should also be `select` and only
        // reference DIRECT or 🚀 节点选择.
        for derivedName in ["🎯 全球直连", "🐟 漏网之鱼"] {
            let derived = try #require(groups.first { ($0["name"] as? String) == derivedName })
            #expect(derived["type"] as? String == "select")
            let derivedChildren = try #require(derived["proxies"] as? [String])
            let allowed = Set(["DIRECT", "🚀 节点选择"])
            #expect(Set(derivedChildren).isSubset(of: allowed))
        }
    }

    @Test
    func `sanitized fixture contains no real server credentials`() throws {
        // Belt-and-braces: if the sanitization step ever regresses, this
        // test fails before the fixture lands on someone's disk.
        let data = try Self.loadFixture("clash_emoji_groups_realworld")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("113.46.151.169"))
        #expect(!text.contains("3a27514d-b184-3fac-8980-0c77a59cf994"))
        #expect(!text.contains("baidu.com"))
        #expect(!text.contains("MANAGED-CONFIG"))
    }

    /// Locates a fixture YAML inside the test bundle. Resources land flat
    /// regardless of the `Fixtures/yaml/` source path, so look up by leaf
    /// name.
    private static func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "yaml"),
            "fixture \(name).yaml not found in test bundle",
        )
        return try Data(contentsOf: url)
    }

    /// Class-bound anchor so `Bundle(for:)` resolves to the test bundle.
    private final class FixtureAnchor {}
}
