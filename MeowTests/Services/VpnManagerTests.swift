import Foundation
@testable import meow_ios
import MeowModels
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

    // MARK: - Network-change auto-reconnect

    /// Canonical "wifi came back" edge: user wanted the tunnel up, NE fell to
    /// `.disconnected` while offline, NWPathMonitor delivers
    /// unsatisfied → satisfied. We must reconnect.
    @Test
    func `shouldReconnect fires on unsatisfied to satisfied edge while user wants connection and tunnel is stopped`() {
        #expect(VpnManager.shouldReconnect(
            previousSatisfied: false,
            currentSatisfied: true,
            wantsConnection: true,
            stage: .stopped,
        ))
    }

    /// Same edge but in `.error` (e.g. extension aborted startup). Still the
    /// user's intent is "be connected" so a recovered network should retry.
    @Test
    func `shouldReconnect fires from error stage`() {
        #expect(VpnManager.shouldReconnect(
            previousSatisfied: false,
            currentSatisfied: true,
            wantsConnection: true,
            stage: .error,
        ))
    }

    /// `.idle` is the pre-attach default; if the path satisfied edge happens
    /// before refresh() lands the manager (e.g. cold launch offline → online),
    /// we still want to reconnect rather than wait for the next path change.
    @Test
    func `shouldReconnect fires from idle stage`() {
        #expect(VpnManager.shouldReconnect(
            previousSatisfied: false,
            currentSatisfied: true,
            wantsConnection: true,
            stage: .idle,
        ))
    }

    /// User explicitly disconnected — a wifi handoff after that must NOT
    /// silently bring the tunnel back up.
    @Test
    func `shouldReconnect does not fire when user does not want connection`() {
        #expect(!VpnManager.shouldReconnect(
            previousSatisfied: false,
            currentSatisfied: true,
            wantsConnection: false,
            stage: .stopped,
        ))
    }

    /// Steady-state path delivery on an already-online device: previous and
    /// current both satisfied. Without the !previous guard we'd reconnect on
    /// every benign path callback (interface metric tweaks, DNS changes).
    @Test
    func `shouldReconnect does not fire when path was already satisfied`() {
        #expect(!VpnManager.shouldReconnect(
            previousSatisfied: true,
            currentSatisfied: true,
            wantsConnection: true,
            stage: .stopped,
        ))
    }

    /// Network just dropped (satisfied → unsatisfied). Reconnect attempts
    /// while offline are doomed and would just churn `.connecting` → `.error`.
    @Test
    func `shouldReconnect does not fire on satisfied to unsatisfied edge`() {
        #expect(!VpnManager.shouldReconnect(
            previousSatisfied: true,
            currentSatisfied: false,
            wantsConnection: true,
            stage: .stopped,
        ))
    }

    /// Tunnel is already up; a transient unsatisfied → satisfied flap
    /// (briefly losing all interfaces during a handoff) must not double-start
    /// the NE — iOS's own `.reasserting` machinery owns recovery here.
    @Test
    func `shouldReconnect does not fire while already connected`() {
        #expect(!VpnManager.shouldReconnect(
            previousSatisfied: false,
            currentSatisfied: true,
            wantsConnection: true,
            stage: .connected,
        ))
    }

    /// Same protection during the connecting / disconnecting in-between
    /// stages: kicking off a second startVPNTunnel mid-transition is racy and
    /// produces undefined NEVPNStatus sequences.
    @Test
    func `shouldReconnect does not fire while a transition is in flight`() {
        for stage in [VpnStage.connecting, .stopping] {
            #expect(!VpnManager.shouldReconnect(
                previousSatisfied: false,
                currentSatisfied: true,
                wantsConnection: true,
                stage: stage,
            ))
        }
    }

    /// On a fresh `VpnManager` the user has not yet asked to connect, so any
    /// network-path callback (cold launch, locale change, etc.) must be a
    /// silent no-op — no stage churn, no spurious lastError.
    @Test
    func `handleNetworkPathChange is a no-op when user has not asked to connect`() {
        let mgr = VpnManager()
        mgr.handleNetworkPathChange(satisfied: false)
        mgr.handleNetworkPathChange(satisfied: true)
        #expect(mgr.stage == .idle)
        #expect(mgr.lastError == nil)
        #expect(mgr.wantsConnection == false)
    }
}
