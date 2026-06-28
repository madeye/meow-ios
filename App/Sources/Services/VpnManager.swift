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
    /// selections — meow-rs resets group state on every engine start,
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

    /// Load (or create) the packet-tunnel configuration. Called on app launch
    /// and after user edits.
    ///
    /// Critical: when an existing profile is found, this attaches without
    /// re-saving the configuration. iOS allows only one VPN profile in the
    /// "active" slot — calling `saveToPreferences()` with `isEnabled = true`
    /// re-claims that slot, deactivating whatever other VPN app was active.
    /// Doing that on every cold-launch is how "opening meow disconnects my
    /// other VPN" regressions appear. Slot ownership is claimed only by
    /// explicit user actions: `connect()`, or the first-install branch here.
    /// On-demand pref changes are synced only when we already own the slot.
    func refresh() async {
        if Self.usesMockTunnel {
            refreshMockTunnel()
            return
        }

        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first {
                let want = Preferences.load(from: AppGroup.defaults).onDemand
                if existing.isEnabled, existing.isOnDemandEnabled != want {
                    existing.isOnDemandEnabled = want
                    try await existing.saveToPreferences()
                    try await existing.loadFromPreferences()
                }
                attach(existing)
            } else {
                let mgr = NETunnelProviderManager()
                configureIfNeeded(mgr)
                try await mgr.saveToPreferences()
                try await mgr.loadFromPreferences()
                attach(mgr)
            }
        } catch {
            lastError = error.localizedDescription
            stage = .error
        }
    }

    /// Kick off a connect. Caller should have already written the selected
    /// profile YAML into the App Group container. Missing GeoIP/ASN/geosite
    /// DBs are now downloaded inside the Rust engine on first boot (routed
    /// through the user's first proxy via `internal_http`), so the app
    /// process does not run a pre-flight engine of its own.
    func connect() async {
        if Self.usesMockTunnel {
            await connectMockTunnel()
            return
        }

        lastError = nil
        // Always reload the manager from preferences before connecting, not
        // just when it's nil. When another VPN app becomes active, iOS disables
        // our saved configuration, and the manager object we cached at launch
        // goes stale — `startVPNTunnel()` then throws (`configurationStale` /
        // `configurationDisabled`) and the only way out was to force-quit meow
        // so the next launch's `refresh()` loaded a fresh object. `refresh()`
        // reloads (or recreates) and reattaches a current manager, and is
        // written to NOT steal the VPN slot from other apps, so calling it on
        // every connect is safe.
        await refresh()
        guard let manager else { return }
        do {
            let prefs = Preferences.load(from: AppGroup.defaults)
            var dirty = false
            if !manager.isEnabled {
                manager.isEnabled = true
                dirty = true
            }
            if (manager.onDemandRules ?? []).isEmpty {
                manager.onDemandRules = [NEOnDemandRuleConnect()]
                dirty = true
            }
            if manager.isOnDemandEnabled != prefs.onDemand {
                manager.isOnDemandEnabled = prefs.onDemand
                dirty = true
            }
            if dirty {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            try await startTunnel(manager)
        } catch {
            lastError = error.localizedDescription
            stage = .error
        }
    }

    /// Start the tunnel, reloading once and retrying if iOS reports the local
    /// configuration is stale. Even after a fresh load, another VPN app
    /// mutating the shared VPN preferences between our load and our
    /// `startVPNTunnel()` call can leave the object stale; the documented
    /// recovery is to reload from preferences and try again.
    private func startTunnel(_ mgr: NETunnelProviderManager) async throws {
        do {
            try mgr.connection.startVPNTunnel()
        } catch let error as NEVPNError where error.code == .configurationStale {
            try await mgr.loadFromPreferences()
            try mgr.connection.startVPNTunnel()
        }
    }

    /// Disable on-demand first, then tear down the tunnel. iOS reclaims the NE
    /// under media/CPU/network pressure and normally auto-reconnects via the
    /// on-demand rule — so we have to actively disable it when the user
    /// intentionally wants the VPN off.
    func disconnect() async {
        if Self.usesMockTunnel {
            await disconnectMockTunnel()
            return
        }

        guard let manager else {
            clearStaleActiveExtensionState()
            applyConnectionStatus(.disconnected)
            return
        }
        let status = manager.connection.status
        guard Self.canStopTunnel(status) else {
            // If the app was replaced while the extension was running, the
            // persisted App-Group state can still say "connected" even though
            // iOS has already invalidated/disconnected the NE profile. A stop
            // request cannot produce a status notification in that state, so
            // repair the UI immediately and allow the next tap to connect.
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try? await manager.saveToPreferences()
            }
            clearStaleActiveExtensionState()
            applyConnectionStatus(status)
            return
        }
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()
    }

    // MARK: - Private

    private func configureIfNeeded(_ mgr: NETunnelProviderManager) {
        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.tangzixiang.meow.PacketTunnel"
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
        mgr.onDemandRules = [NEOnDemandRuleConnect()]
        // On-demand auto-reconnects after iOS reclaims the NE under
        // media/CPU/network pressure, but it also makes the VPN "sticky" in
        // a way some users dislike (any network change resurrects the
        // tunnel). Off by default; surfaced as a toggle in SettingsView.
        mgr.isOnDemandEnabled = Preferences.load(from: AppGroup.defaults).onDemand
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

    /// Update state from the background extension's persisted state. The NE
    /// connection status stays the lifecycle authority: app replacement can
    /// strand a stale active `state.json` after the old provider has gone away,
    /// so an extension snapshot must never resurrect a tunnel iOS already tore
    /// down (which would leave the Home toggle calling `stop` forever).
    func applyExtensionState(_ state: VpnState) {
        if Self.usesMockTunnel {
            applyMockState(state)
            return
        }

        guard let status = manager?.connection.status else {
            applyExtensionStateWithoutConnection(state)
            return
        }
        reconcileExtensionState(state, with: status)
    }

    /// Merge an extension snapshot with the live NE status.
    private func reconcileExtensionState(_ state: VpnState, with status: NEVPNStatus) {
        switch status {
        case .invalid, .disconnected:
            // No live tunnel. Drop a stale "active" snapshot so the toggle
            // doesn't keep stopping a profile that no longer exists.
            if state.stage.isActive {
                clearStaleActiveExtensionState()
            }
            if state.stage == .error {
                applyExtensionError(state)
            } else {
                applyConnectionStatus(status)
            }
        case .connected, .connecting, .reasserting, .disconnecting:
            // Live tunnel — trust the snapshot's richer stage/error.
            stage = state.stage
            if let msg = state.errorMessage, !msg.isEmpty {
                lastError = msg
            }
        @unknown default:
            applyConnectionStatus(status)
        }
    }

    /// Fallback used before a `NETunnelProviderManager` is attached.
    private func applyExtensionStateWithoutConnection(_ state: VpnState) {
        stage = state.stage
        if let msg = state.errorMessage, !msg.isEmpty {
            lastError = msg
        }
    }

    private func applyExtensionError(_ state: VpnState) {
        stage = .error
        if let msg = state.errorMessage, !msg.isEmpty {
            lastError = msg
        }
    }

    /// Rewrite an "active" App-Group snapshot to `.stopped` once the NE status
    /// proves there is no live tunnel, so the next read doesn't resurrect it.
    private func clearStaleActiveExtensionState() {
        guard let state = SharedStore.readState(), state.stage.isActive else { return }
        try? SharedStore.writeState(VpnState(stage: .stopped))
    }

    private nonisolated static func canStopTunnel(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        case .invalid, .disconnected:
            return false
        @unknown default:
            return false
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

private extension VpnManager {
    nonisolated static var usesMockTunnel: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    nonisolated static var shouldResetMockState: Bool {
        ProcessInfo.processInfo.arguments.contains("-ResetState")
    }

    func refreshMockTunnel() {
        if Self.shouldResetMockState {
            applyMockState(.init(stage: .stopped))
            return
        }

        guard let state = SharedStore.readState(), state.errorMessage == nil else {
            applyMockState(.init(stage: .stopped))
            return
        }
        applyMockState(state)
    }

    func connectMockTunnel() async {
        lastError = nil
        applyMockState(.init(stage: .connecting))
        try? await Task.sleep(for: .milliseconds(250))
        let current = SharedStore.readState()
        applyMockState(.init(
            stage: .connected,
            profileID: current?.profileID,
            profileName: current?.profileName,
            startedAt: current?.startedAt ?? Date(),
        ))
    }

    func disconnectMockTunnel() async {
        lastError = nil
        applyMockState(.init(stage: .stopping))
        try? await Task.sleep(for: .milliseconds(150))
        applyMockState(.init(stage: .stopped))
    }

    func applyMockState(_ state: VpnState) {
        let previous = stage
        stage = state.stage
        lastError = state.stage == .error ? state.errorMessage : nil
        try? SharedStore.writeState(.init(
            stage: stage,
            profileID: state.profileID,
            profileName: state.profileName,
            errorMessage: lastError,
            startedAt: state.startedAt,
        ))
        if stage == .connected, previous != .connected {
            onConnected?()
        }
    }
}
