import Foundation
@testable import meow_ios
import Testing

@Suite("SelectedProxyRestorer", .tags(.service))
struct SelectedProxyRestorerTests {
    actor Recorder {
        var calls: [(String, String)] = []
        var failOn: Set<String> = []

        func record(_ group: String, _ proxy: String) async throws {
            if failOn.contains(group) {
                throw NSError(domain: "test", code: 404)
            }
            calls.append((group, proxy))
        }

        func fail(on groups: [String]) {
            failOn = Set(groups)
        }

        var captured: [(String, String)] {
            calls
        }
    }

    @Test
    func `restore calls select for every entry in alphabetical group order`() async {
        let rec = Recorder()
        let stale = await SelectedProxyRestorer.restore(
            selections: ["Proxy": "node-a", "Auto": "auto", "Region": "hk-01"],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        let calls = await rec.captured
        #expect(stale.isEmpty)
        #expect(calls.map(\.0) == ["Auto", "Proxy", "Region"])
        #expect(calls.map(\.1) == ["auto", "node-a", "hk-01"])
    }

    @Test
    func `restore on empty map issues no calls and no stale entries`() async {
        let rec = Recorder()
        let stale = await SelectedProxyRestorer.restore(
            selections: [:],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        #expect(stale.isEmpty)
        let calls = await rec.captured
        #expect(calls.isEmpty)
    }

    @Test
    func `failed selects are reported as stale, others still apply`() async {
        let rec = Recorder()
        await rec.fail(on: ["Region"])
        let stale = await SelectedProxyRestorer.restore(
            selections: ["Proxy": "node-a", "Region": "missing"],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        let calls = await rec.captured
        #expect(stale == ["Region"])
        #expect(calls.map(\.0) == ["Proxy"])
    }
}
