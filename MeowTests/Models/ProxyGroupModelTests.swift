@testable import meow_ios
import Testing

/// `ProxyGroupModel.build(from:)` projection tests.
///
/// Regression coverage for issue #180: members that are absent from the flat
/// `/proxies` dict (nested group references, or proxies sourced from
/// `proxy-providers:` slots that meow only exposes via `/providers/proxies`)
/// must still render as selectable rows instead of being silently dropped.
@Suite("ProxyGroupModel.build projection", .tags(.model))
struct ProxyGroupModelTests {
    private func proxy(
        _ name: String,
        type: String,
        all: [String]? = nil,
        now: String? = nil,
        delay: Int? = nil,
    ) -> Proxy {
        Proxy(
            name: name,
            type: type,
            now: now,
            all: all,
            history: delay.map { [Proxy.History(time: "", delay: $0)] },
        )
    }

    @Test
    func `members absent from the dict render as stub children, not dropped`() throws {
        // "Apple" lists DIRECT (a leaf present in dict) plus three members that
        // are not present as dict keys — the issue #180 nested/provider case.
        let dict: [String: Proxy] = [
            "DIRECT": proxy("DIRECT", type: "Direct"),
            "Apple": proxy("Apple", type: "Selector", all: ["DIRECT", "Proxy Select", "US", "HK"]),
        ]

        let groups = ProxyGroupModel.build(from: dict)
        let apple = try #require(groups.first { $0.name == "Apple" })

        // All four members appear, in declared order (previously only DIRECT).
        #expect(apple.children.map(\.name) == ["DIRECT", "Proxy Select", "US", "HK"])

        let stub = try #require(apple.children.first { $0.name == "US" })
        #expect(stub.type == "")
        #expect(stub.delay == nil)
        #expect(stub.id == "US")
    }

    @Test
    func `members present in the dict resolve to their real type and delay`() throws {
        let dict: [String: Proxy] = [
            "DIRECT": proxy("DIRECT", type: "Direct"),
            "Proxy Select": proxy("Proxy Select", type: "Selector", all: ["DIRECT"]),
            "node-01": proxy("node-01", type: "Shadowsocks", delay: 42),
            "Apple": proxy("Apple", type: "Selector", all: ["Proxy Select", "node-01", "US"]),
        ]

        let groups = ProxyGroupModel.build(from: dict)
        let apple = try #require(groups.first { $0.name == "Apple" })

        let select = try #require(apple.children.first { $0.name == "Proxy Select" })
        #expect(select.type == "Selector")

        let node = try #require(apple.children.first { $0.name == "node-01" })
        #expect(node.type == "Shadowsocks")
        #expect(node.delay == 42)

        // The unresolvable member still appears as a stub alongside resolved ones.
        let stub = try #require(apple.children.first { $0.name == "US" })
        #expect(stub.type == "")
        #expect(stub.delay == nil)
    }

    @Test
    func `only selectable group types are surfaced and GLOBAL is hidden`() {
        let dict: [String: Proxy] = [
            "DIRECT": proxy("DIRECT", type: "Direct"),
            "GLOBAL": proxy("GLOBAL", type: "Selector", all: ["DIRECT"]),
            "Auto": proxy("Auto", type: "URLTest", all: ["DIRECT"]),
            "Picker": proxy("Picker", type: "Selector", all: ["DIRECT"]),
        ]

        let names = ProxyGroupModel.build(from: dict).map(\.name)
        #expect(names == ["Auto", "Picker"])
    }
}
