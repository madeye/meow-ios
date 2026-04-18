import Foundation
import MeowIPC
import MeowModels
import Observation
import SwiftData

/// Top-level observable that wires the app's long-lived services together and
/// performs first-launch setup (asset seeding, IPC observer registration).
@MainActor
@Observable
final class AppModel {
    let vpnManager: VpnManager
    let mihomoAPI: MihomoAPI
    let subscriptionService: SubscriptionService
    let ipcBridge: AppIPCBridge

    private var didBootstrap = false

    init() {
        // Export XDG_CONFIG_HOME before any FFI callsite that might resolve
        // GEOIP rules (e.g. YamlEditorView's MihomoConfigValidator →
        // meow_engine_validate_config). std::env::set_var is per-process, so
        // each of {App, PacketTunnel} needs its own call — PacketTunnel does
        // the same in TunnelEngine.start.
        AppGroup.containerURL.path.withCString { meow_core_set_home_dir($0) }

        let defaults = AppGroup.defaults
        let prefs = Preferences.load(from: defaults)
        vpnManager = VpnManager()
        mihomoAPI = MihomoAPI(port: 9090, secret: defaults.string(forKey: PreferenceKey.apiSecret) ?? "")
        subscriptionService = SubscriptionService(
            modelContext: AppModelContainer.shared.container.mainContext,
        )
        ipcBridge = AppIPCBridge()
        _ = prefs
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        vpnManager.onConnected = { [weak self] in
            self?.replaySelectedProxiesOnConnect()
        }
        await AssetSeeder.seedIfNeeded()
        await vpnManager.refresh()
        ipcBridge.start()
    }

    /// Re-issues the active profile's persisted `selectedProxies` after the
    /// engine starts. mihomo-rust drops in-memory group state on every
    /// engine.start, so without this the UI shows the YAML defaults instead
    /// of what the user last picked. Stale entries (group/proxy renamed or
    /// removed since the last save) are dropped and persisted back.
    private func replaySelectedProxiesOnConnect() {
        let context = AppModelContainer.shared.container.mainContext
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.isSelected })
        guard let profile = try? context.fetch(descriptor).first else { return }
        let selections = profile.selectedProxies
        guard !selections.isEmpty else { return }
        let api = mihomoAPI
        Task { @MainActor in
            let stale = await SelectedProxyRestorer.restore(
                selections: selections,
                select: { group, name in try await api.selectProxy(group: group, name: name) },
            )
            guard !stale.isEmpty else { return }
            var updated = profile.selectedProxies
            for group in stale {
                updated.removeValue(forKey: group)
            }
            profile.selectedProxies = updated
            try? context.save()
        }
    }
}
