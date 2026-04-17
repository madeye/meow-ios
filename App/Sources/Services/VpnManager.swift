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
    private(set) var lastError: VpnManagerError?

    /// Structured error surface. `lastError.label` is the PRD §4.3 text
    /// rendered at `home.error` (accessibility id) and pinned by
    /// `LocalE2ETests` — keeping domain + code + message machine-parseable
    /// means a rename (`localizedDescription` drift, string interpolation
    /// typo) breaks the test instead of silently swallowing the change.
    struct VpnManagerError: Sendable, Equatable {
        let domain: String
        let code: Int
        let message: String

        init(_ error: Error) {
            let ns = error as NSError
            self.domain = ns.domain
            self.code = ns.code
            self.message = error.localizedDescription
        }

        /// `<domain>(<code>): <message>` — pinned by `LocalE2ETests`.
        var label: String { "\(domain)(\(code)): \(message)" }
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
            lastError = VpnManagerError(error)
            stage = .error
        }
    }

    /// Kick off a connect. Caller should have already written the selected
    /// profile YAML into the App Group container.
    func connect() async {
        do {
            if manager == nil { await refresh() }
            guard let manager else { return }
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = VpnManagerError(error)
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
        proto.serverAddress = "meow"
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
                self.stage = self.map(status)
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
