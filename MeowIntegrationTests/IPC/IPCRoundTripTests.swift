import XCTest
@testable import MeowIPC
@testable import MeowModels

/// App ↔ Extension round-trip tests. Runs in the app process but observes
/// the real extension's CFNotification emissions.
final class IPCRoundTripTests: XCTestCase {

    func testCommandStartTriggersConnectWithin500ms() async throws {
        throw XCTSkip("blocked on T3.6 + T4.3")
        // queueIntent(.start), post command, wait for state = .connecting
    }

    func testTrafficUpdatesAt2Hz() async throws {
        throw XCTSkip("blocked on T3.6")
        // observe com.meow.vpn.traffic for 3s — expect ≥ 6 notifications
    }

    func testRapidCommandBurstIsDeduped() async throws {
        throw XCTSkip("blocked on T3.6")
        // post 10 start commands in 1s → exactly one connect attempt
    }

    func testOversizedStatePayloadFallsBackToFile() async throws {
        throw XCTSkip("blocked on T3.6 design decision")
    }
}
