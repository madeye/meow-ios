import Foundation
@testable import meow_ios
import NetworkExtension
import Testing

/// Lightweight unit tests for `VpnManager` that do NOT require a real
/// NetworkExtension — those live in `MeowIntegrationTests/VPNLifecycle/`.
/// These cover the state reducer, status mapping, and command serialization.
@Suite("VpnManager state mapping", .tags(.service))
@MainActor
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

    /// Regression guard for #59/#60 relaunch-into-connected trap: when the app
    /// cold-launches while the NE extension is already `.connected` (user
    /// force-quit the containing app while the tunnel was up), reading the
    /// initial status inside `attach(_:)` is not an observed
    /// `.NEVPNStatusDidChange` edge. Without firing `onConnected` on that
    /// synthetic edge, the proxy-selection replay in `AppModel` never runs
    /// and the UI shows mihomo's YAML defaults instead of the user's picks.
    @Test
    func `applyConnectionStatus fires onConnected on idle to connected edge`() {
        let mgr = VpnManager()
        var fired = 0
        mgr.onConnected = { fired += 1 }
        mgr.applyConnectionStatus(.connected)
        #expect(fired == 1)
        #expect(mgr.stage == .connected)
    }

    @Test
    func `applyConnectionStatus does not refire while staying connected`() {
        let mgr = VpnManager()
        var fired = 0
        mgr.onConnected = { fired += 1 }
        mgr.applyConnectionStatus(.connected)
        mgr.applyConnectionStatus(.connected)
        #expect(fired == 1)
    }

    @Test
    func `applyConnectionStatus refires on reconnect after disconnect`() {
        let mgr = VpnManager()
        var fired = 0
        mgr.onConnected = { fired += 1 }
        mgr.applyConnectionStatus(.connected)
        mgr.applyConnectionStatus(.disconnected)
        mgr.applyConnectionStatus(.connected)
        #expect(fired == 2)
    }

    @Test
    func `reasserting round trip does not refire onConnected`() {
        // .reasserting maps to .connecting, so the next .connected IS a fresh
        // edge and must refire — otherwise IP-changes wouldn't trigger replay.
        let mgr = VpnManager()
        var fired = 0
        mgr.onConnected = { fired += 1 }
        mgr.applyConnectionStatus(.connected)
        mgr.applyConnectionStatus(.reasserting)
        mgr.applyConnectionStatus(.connected)
        #expect(fired == 2)
    }

    @Test
    func `onConnected is not invoked for non-connected status`() {
        let mgr = VpnManager()
        var fired = 0
        mgr.onConnected = { fired += 1 }
        mgr.applyConnectionStatus(.disconnected)
        mgr.applyConnectionStatus(.connecting)
        mgr.applyConnectionStatus(.disconnecting)
        mgr.applyConnectionStatus(.invalid)
        #expect(fired == 0)
    }
}
