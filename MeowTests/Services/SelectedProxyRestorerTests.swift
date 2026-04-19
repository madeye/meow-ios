import Foundation
@testable import meow_ios
import Testing

@Suite("SelectedProxyRestorer", .tags(.service))
struct SelectedProxyRestorerTests {
    actor Recorder {
        var calls: [(String, String)] = []
        var failures: [String: Error] = [:]

        func record(_ group: String, _ proxy: String) async throws {
            if let err = failures[group] {
                throw err
            }
            calls.append((group, proxy))
        }

        func fail(on group: String, with error: Error) {
            failures[group] = error
        }

        var captured: [(String, String)] {
            calls
        }
    }

    @Test
    func `restore calls select for every entry in alphabetical group order`() async {
        let rec = Recorder()
        let outcome = await SelectedProxyRestorer.restore(
            selections: ["Proxy": "node-a", "Auto": "auto", "Region": "hk-01"],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        let calls = await rec.captured
        #expect(outcome.stale.isEmpty)
        #expect(outcome.transient.isEmpty)
        #expect(calls.map(\.0) == ["Auto", "Proxy", "Region"])
        #expect(calls.map(\.1) == ["auto", "node-a", "hk-01"])
    }

    @Test
    func `restore on empty map issues no calls and no outcomes`() async {
        let rec = Recorder()
        let outcome = await SelectedProxyRestorer.restore(
            selections: [:],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        #expect(outcome.stale.isEmpty)
        #expect(outcome.transient.isEmpty)
        let calls = await rec.captured
        #expect(calls.isEmpty)
    }

    @Test
    func `HTTP 404 is reported as stale, others still apply`() async {
        let rec = Recorder()
        await rec.fail(on: "Region", with: MihomoAPIError.http(status: 404))
        let outcome = await SelectedProxyRestorer.restore(
            selections: ["Proxy": "node-a", "Region": "missing"],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        let calls = await rec.captured
        #expect(outcome.stale == ["Region"])
        #expect(outcome.transient.isEmpty)
        #expect(calls.map(\.0) == ["Proxy"])
    }

    @Test
    func `URLError is reported as transient, not stale`() async {
        // Regression guard for the #59 replay-race bug: the in-process
        // api_server may not have bound :9090 by the time replay fires on
        // NEVPNStatus=.connected. A connection-refused URLError must NOT
        // bubble through to the caller as `stale` — doing so silently
        // wipes the user's persisted proxy-group selections.
        let rec = Recorder()
        await rec.fail(on: "Proxy", with: URLError(.cannotConnectToHost))
        await rec.fail(on: "Region", with: URLError(.timedOut))
        let outcome = await SelectedProxyRestorer.restore(
            selections: ["Proxy": "node-a", "Auto": "auto", "Region": "hk-01"],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        let calls = await rec.captured
        #expect(outcome.stale.isEmpty)
        #expect(outcome.transient == ["Proxy", "Region"])
        #expect(calls.map(\.0) == ["Auto"])
    }

    @Test
    func `HTTP 5xx is reported as transient, not stale`() async {
        let rec = Recorder()
        await rec.fail(on: "Proxy", with: MihomoAPIError.http(status: 503))
        let outcome = await SelectedProxyRestorer.restore(
            selections: ["Proxy": "node-a", "Auto": "auto"],
            select: { group, proxy in try await rec.record(group, proxy) },
        )
        let calls = await rec.captured
        #expect(outcome.stale.isEmpty)
        #expect(outcome.transient == ["Proxy"])
        #expect(calls.map(\.0) == ["Auto"])
    }
}
