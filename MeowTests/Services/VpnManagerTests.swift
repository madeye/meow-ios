import Testing
import Foundation

/// Lightweight unit tests for `VpnManager` that do NOT require a real
/// NetworkExtension — those live in `MeowIntegrationTests/VPNLifecycle/`.
/// These cover the state reducer, status mapping, and command serialization.
@Suite("VpnManager state mapping", .tags(.service))
struct VpnManagerTests {

    @Test("NEVPNStatus maps to VpnStage", .disabled("blocked on T4.2"))
    func testStatusMapping() {
        // .invalid → .idle
        // .disconnected → .stopped
        // .connecting → .connecting
        // .connected → .connected
        // .reasserting → .connecting
        // .disconnecting → .stopping
    }

    @Test("connect while already connecting is a no-op", .disabled("blocked on T4.2"))
    func testConnectIdempotent() {
        // calling connect twice in a row should issue exactly one startVPNTunnel
    }

    @Test("error stage populates errorMessage", .disabled("blocked on T4.2"))
    func testErrorMessagePropagated() {
        // extension writes state with stage=.error, message="dial timeout"
        // VpnManager publishes state with same message
    }
}
