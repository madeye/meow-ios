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

    /// Fires once each time `stage` transitions into `.connected`. Wired by
    /// `AppModel` to replay persisted proxy-group selections via
    /// `SelectedProxyRestorer` — mihomo-rust resets group state on every
    /// engine start, so the app owns persistence.
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
    /// profile YAML into the App Group container.
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

    func disconnect() {
        manager?.connection.stopVPNTunnel()
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
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "meow"
        mgr.isEnabled = true
    }

    private func attach(_ mgr: NETunnelProviderManager) {
        manager = mgr
        stage = map(mgr.connection.status)
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: mgr.connection,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            let status = mgr.connection.status
            Task { @MainActor in
                let previous = self.stage
                let next = self.map(status)
                self.stage = next
                // When the extension aborts startup (engine.start throws) the
                // connection transitions straight to .disconnected with no
                // thrown NEVPNManagerError. The provider writes the Rust error
                // into shared state before returning — surface it here so the
                // UI can show the actual reason instead of a silent toggle.
                if status == .disconnected, let msg = SharedStore.readState()?.errorMessage, !msg.isEmpty {
                    self.lastError = msg
                }
                // Fire onConnected exactly once per connect transition. The
                // observer can run repeatedly (e.g. .reasserting → .connected
                // round trips), so guard on the actual stage edge.
                if next == .connected, previous != .connected {
                    self.onConnected?()
                }
            }
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
