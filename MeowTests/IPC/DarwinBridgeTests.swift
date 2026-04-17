import Testing
import Foundation
@testable import MeowIPC

@Suite("DarwinBridge notification timing", .tags(.ipc))
struct DarwinBridgeTests {

    @Test("post → observe round-trip within 50ms", .disabled("timing-sensitive; runs on-simulator only"))
    func testPostObserveLatency() async {
        // let received = expectation(fulfilled once)
        // let observer = DarwinBridge.addObserver(for: .state) { received.fulfill() }
        // DarwinBridge.post(.state)
        // wait 50ms
        // DarwinBridge.removeObserver(observer)
    }

    @Test("observer is cleaned up on deinit — no leaks", .disabled("requires leak detection"))
    func testObserverCleanup() {
        // create + drop observer, verify no stale callbacks fire
    }
}
