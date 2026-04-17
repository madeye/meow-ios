import NetworkExtension
import XCTest

/// Drives `NETunnelProviderManager` and observes `NEVPNStatusDidChange`.
/// See TEST_STRATEGY §4.1 for the scenario matrix.
final class TunnelLifecycleTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testStartTunnelReachesConnectedWithin8s() throws {
        throw XCTSkip("blocked on T3.3 end-to-end config path")
        // let manager = try await loadManager()
        // try manager.connection.startVPNTunnel()
        // let status = try await waitFor(status: .connected, manager: manager, timeout: 8)
        // XCTAssertEqual(status, .connected)
    }

    func testStopTunnelCleansUpTun() throws {
        throw XCTSkip("blocked on T3.3")
        // after stop, `ifconfig` has no utun attributable to us
    }

    func testMalformedConfigTransitionsToDisconnectedWithError() throws {
        throw XCTSkip("blocked on T3.3")
    }

    func testAppForceQuitPreservesExtensionSession() throws {
        throw XCTSkip("manual test — requires separate app process")
    }

    func testReconnectAfterSleepWakeWithin10s() throws {
        throw XCTSkip("manual test — requires device sleep cycle")
    }
}
