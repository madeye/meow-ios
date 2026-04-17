import Foundation
@testable import MeowIPC
@testable import MeowModels
import Testing

/// App-side coverage for ``SharedStore``. The package-level tests in
/// `MeowSharedTests` focus on plain-data serialization; these tests verify
/// the app's consumption of the shared container — including the intent
/// queue behavior (take-once semantics).
@Suite("SharedStore app-side", .tags(.ipc))
struct SharedStoreTests {
    @Test(.disabled("requires App Group entitlement at test time"))
    func `queueIntent + takeIntent is take-once`() {
        // try SharedStore.queueIntent(.init(command: .start, profileID: "p1"))
        // #expect(SharedStore.takeIntent()?.command == .start)
        // #expect(SharedStore.takeIntent() == nil, "second take must return nil")
    }

    @Test(.disabled("requires App Group entitlement"))
    func `writeState is atomic — partial file never visible`() {
        // write twice in rapid succession; ensure no reader observes a truncated file
    }

    @Test(.disabled("requires App Group entitlement"))
    func `malformed state file reads as nil, not crash`() {
        // write "{{garbage" to stateURL; readState() returns nil
    }
}

extension Tag {
    @Tag static var ipc: Self
}
