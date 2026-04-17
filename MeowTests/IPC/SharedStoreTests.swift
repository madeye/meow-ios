import Testing
import Foundation
@testable import MeowModels
@testable import MeowIPC

/// App-side coverage for ``SharedStore``. The package-level tests in
/// `MeowSharedTests` focus on plain-data serialization; these tests verify
/// the app's consumption of the shared container — including the intent
/// queue behavior (take-once semantics).
@Suite("SharedStore app-side", .tags(.ipc))
struct SharedStoreTests {

    @Test("queueIntent + takeIntent is take-once", .disabled("requires App Group entitlement at test time"))
    func testIntentTakeOnce() throws {
        // try SharedStore.queueIntent(.init(command: .start, profileID: "p1"))
        // #expect(SharedStore.takeIntent()?.command == .start)
        // #expect(SharedStore.takeIntent() == nil, "second take must return nil")
    }

    @Test("writeState is atomic — partial file never visible", .disabled("requires App Group entitlement"))
    func testStateAtomic() throws {
        // write twice in rapid succession; ensure no reader observes a truncated file
    }

    @Test("malformed state file reads as nil, not crash", .disabled("requires App Group entitlement"))
    func testMalformedStateReturnsNil() throws {
        // write "{{garbage" to stateURL; readState() returns nil
    }
}

extension Tag {
    @Tag static var ipc: Self
}
