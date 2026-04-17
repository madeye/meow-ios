import Foundation
@testable import MeowIPC
import Testing

@Suite("DarwinBridge notification timing", .tags(.ipc))
struct DarwinBridgeTests {
    @Test(.disabled("timing-sensitive; runs on-simulator only"))
    func `post → observe round-trip within 50ms`() {
        // let received = expectation(fulfilled once)
        // let observer = DarwinBridge.addObserver(for: .state) { received.fulfill() }
        // DarwinBridge.post(.state)
        // wait 50ms
        // DarwinBridge.removeObserver(observer)
    }

    @Test(.disabled("requires leak detection"))
    func `observer is cleaned up on deinit — no leaks`() {
        // create + drop observer, verify no stale callbacks fire
    }
}
