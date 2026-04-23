import Foundation
import MeowIPC
import MeowModels
import NetworkExtension
import Observation

/// Thin wrapper around `NETunnelProviderManager` that the UI observes for
/// connect/disconnect and the current `VpnStage`.
@MainActor
@Observable
final class VpnManager {
    private(set) var stage: VpnStage = .idle
    private(set) var lastError: String?

    /// Fires each time `stage` transitions into `.connected`, including the
    /// synthetic attach-time edge when the tunnel is already connected on
    /// app relaunch. Wired by `AppModel` to replay persisted proxy-group
    /// selections — mihomo-rust resets group state on every engine start,
    /// so the app owns persistence.
    var onConnected: (@MainActor () -> Void)?

    /// Clear the user-visible error banner. Called when the user dismisses it
    /// or when a new connect attempt starts.
    func clearError() {
        lastError = nil
    }

    private var manager: NETunnelProviderManager?
    // nonisolated(unsafe): written only from attach() on MainActor, read from
    // deinit (which is nonisolated). NotificationCenter.removeObserver is
    // thread-safe, so a torn read here is harmless.
    private nonisolated(unsafe) var statusObserver: NSObjectProtocol?

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    /// Load (or create) the packet-tunnel configuration and install it in
    /// Preferences. Called on app launch and after user edits.
    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let mgr = managers.first ?? NETunnelProviderManager()
            configureIfNeeded(mgr)
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
            attach(mgr)
        } catch {
            lastError = error.localizedDescription
            stage = .error
        }
    }

    /// Kick off a connect. Caller should have already written the selected
    /// profile YAML into the App Group container. Re-enables on-demand if
    /// `disconnect` previously turned it off.
    func connect() async {
        lastError = nil
        do {
            if manager == nil { await refresh() }
            guard let manager else { return }
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
            stage = .error
        }
    }

    /// Disable on-demand first, then tear down the tunnel. iOS reclaims the NE
    /// under media/CPU/network pressure and normally auto-reconnects via the
    /// on-demand rule — so we have to actively disable it when the user
    /// intentionally wants the VPN off.
    func disconnect() async {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
    }

    // MARK: - Private

    private func configureIfNeeded(_ mgr: NETunnelProviderManager) {
        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "io.github.madeye.meow.PacketTunnel"
        // RFC 5737 TEST-NET-1 placeholder — iOS 26 rejects non-RFC strings
        // (e.g. "meow") at NEPacketTunnelNetworkSettings construction with
        // "invalid tunnel remote address". The real proxy endpoint lives in
        // the profile YAML consumed by the Rust engine, not here.
        proto.serverAddress = "192.0.2.1"
        proto.providerConfiguration = [
            "appGroup": AppGroup.identifier,
        ]
        // Keep the tunnel alive across screen lock — iOS defaults to false
        // on packet-tunnel providers but we set it explicitly because any
        // future protocol tweak that re-uses the default would regress this.
        proto.disconnectOnSleep = false
        // NOTE: `includeAllNetworks = true` was trialed as an iOS reclaim
        // mitigation. Observed on-device: kill frequency went UP (two
        // reclaims within 40s of each other, same (1,7,9) tuple as before)
        // AND first-reconnect latency regressed from 5.4s to 8.1s. So we
        // explicitly do NOT set it; the on-demand rule below handles the
        // reclaim case invisibly regardless.
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "meow"
        mgr.isEnabled = true
        mgr.onDemandRules = []
        mgr.isOnDemandEnabled = false
    }

    private func attach(_ mgr: NETunnelProviderManager) {
        manager = mgr
        // Reading the initial connection.status is NOT an observed
        // .NEVPNStatusDidChange edge, so on app relaunch into an
        // already-connected tunnel (force-quit while VPN up), the observer
        // alone never fires and the replay-on-connect callback never runs.
        // #60 fixed the cold-connect readiness race; this fires the
        // callback for the relaunch-into-connected edge too.
        applyConnectionStatus(mgr.connection.status)
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: mgr.connection,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            let status = mgr.connection.status
            Task { @MainActor in
                // When the extension aborts startup (engine.start throws) the
                // connection transitions straight to .disconnected with no
                // thrown NEVPNManagerError. The provider writes the Rust error
                // into shared state before returning — surface it here so the
                // UI can show the actual reason instead of a silent toggle.
                if status == .disconnected, let msg = SharedStore.readState()?.errorMessage, !msg.isEmpty {
                    self.lastError = msg
                }
                self.applyConnectionStatus(status)
            }
        }
    }

    /// Update `stage` and fire `onConnected` on the non-connected → connected
    /// edge. Exposed at `internal` so `@testable` consumers can exercise the
    /// edge semantics directly without a real `NETunnelProviderManager`.
    func applyConnectionStatus(_ status: NEVPNStatus) {
        let previous = stage
        let next = map(status)
        stage = next
        if next == .connected, previous != .connected {
            onConnected?()
        }
    }

    private nonisolated func map(_ status: NEVPNStatus) -> VpnStage {
        switch status {
        case .invalid: return .idle
        case .disconnected: return .stopped
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .connecting
        case .disconnecting: return .stopping
        @unknown default: return .idle
        }
    }
}
