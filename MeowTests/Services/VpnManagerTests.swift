import Foundation
import Testing

/// Lightweight unit tests for `VpnManager` that do NOT require a real
/// NetworkExtension — those live in `MeowIntegrationTests/VPNLifecycle/`.
/// These cover the state reducer, status mapping, and command serialization.
@Suite("VpnManager state mapping", .tags(.service))
struct VpnManagerTests {
    @Test(.disabled("blocked on T4.2"))
    func `NEVPNStatus maps to VpnStage`() {
        // .invalid → .idle
        // .disconnected → .stopped
        // .connecting → .connecting
        // .connected → .connected
        // .reasserting → .connecting
        // .disconnecting → .stopping
    }

    @Test(.disabled("blocked on T4.2"))
    func `connect while already connecting is a no-op`() {
        // calling connect twice in a row should issue exactly one startVPNTunnel
    }

    @Test(.disabled("blocked on T4.2"))
    func `error stage populates errorMessage`() {
        // extension writes state with stage=.error, message="dial timeout"
        // VpnManager publishes state with same message
    }
}
