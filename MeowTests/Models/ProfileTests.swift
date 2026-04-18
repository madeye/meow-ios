import Foundation
@testable import meow_ios
import SwiftData
import Testing

/// SwiftData model tests — CRUD, relationship integrity, selected-exclusive
/// invariant. Migration tests (when the schema changes) live alongside.
@Suite("Profile SwiftData model", .tags(.model))
struct ProfileTests {
    @Test(.disabled("blocked on T4.1 Profile model"))
    func `create, fetch, update, delete round-trip`() {
        // let container = try SwiftDataTestContainer.make()
        // insert Profile, fetch by id, mutate name, fetch again, delete, confirm absent
    }

    @Test(.disabled("blocked on T4.1"))
    func `at most one profile can be selected`() {
        // calling markSelected on profile B should deselect A
    }

    @Test
    func `selectedProxies accessor round-trips through JSON`() {
        let profile = Profile(name: "p", url: "https://example.com/a.yaml", yamlContent: "")
        profile.selectedProxies = ["Auto": "auto", "Proxy": "node-01"]
        let parsed = try? JSONDecoder().decode(
            [String: String].self,
            from: Data(profile.selectedProxiesJSON.utf8),
        )
        #expect(parsed == ["Auto": "auto", "Proxy": "node-01"])
        #expect(profile.selectedProxies == ["Auto": "auto", "Proxy": "node-01"])
    }

    @Test
    func `selectedProxies setter overwrites prior entries`() {
        let profile = Profile(name: "p", url: "https://example.com/a.yaml", yamlContent: "")
        profile.selectedProxies = ["Proxy": "node-01"]
        profile.selectedProxies = ["Auto": "auto"]
        #expect(profile.selectedProxies == ["Auto": "auto"])
    }
}

@Suite("DailyTraffic model", .tags(.model))
struct DailyTrafficTests {
    @Test(.disabled("blocked on T4.1"))
    func `upsert by date string`() {
        // two inserts with same "2026-04-17" coalesce — second write accumulates
    }

    @Test(.disabled("blocked on T4.1"))
    func `monthly total matches hand sum`() {
        // seed 30 days, compute total via model query, compare
    }
}

extension Tag {
    @Tag static var model: Self
}
