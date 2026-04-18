import Foundation
import MeowIPC
import MeowModels
import Observation

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

        await AssetSeeder.seedIfNeeded()
        await vpnManager.refresh()
        ipcBridge.start()
    }
}
