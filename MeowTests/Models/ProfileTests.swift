import Testing
import Foundation
import SwiftData

/// SwiftData model tests — CRUD, relationship integrity, selected-exclusive
/// invariant. Migration tests (when the schema changes) live alongside.
@Suite("Profile SwiftData model", .tags(.model))
struct ProfileTests {

    @Test("create, fetch, update, delete round-trip", .disabled("blocked on T4.1 Profile model"))
    func testRoundTrip() throws {
        // let container = try SwiftDataTestContainer.make()
        // insert Profile, fetch by id, mutate name, fetch again, delete, confirm absent
    }

    @Test("at most one profile can be selected", .disabled("blocked on T4.1"))
    func testSelectedExclusive() throws {
        // calling markSelected on profile B should deselect A
    }

    @Test("selectedProxies encodes/decodes as JSON dict", .disabled("blocked on T4.1"))
    func testSelectedProxiesJSON() throws {
        // set ["Proxy": "node-01", "Auto": "auto"], save, reload, compare
    }
}

@Suite("DailyTraffic model", .tags(.model))
struct DailyTrafficTests {

    @Test("upsert by date string", .disabled("blocked on T4.1"))
    func testUpsertByDate() throws {
        // two inserts with same "2026-04-17" coalesce — second write accumulates
    }

    @Test("monthly total matches hand sum", .disabled("blocked on T4.1"))
    func testMonthlySum() throws {
        // seed 30 days, compute total via model query, compare
    }
}

extension Tag {
    @Tag static var model: Self
}
