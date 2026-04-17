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
        #if DEBUG
        UITestsSeeder.seedIfNeeded(modelContext: AppModelContainer.shared.container.mainContext)
        #endif
        await vpnManager.refresh()
        ipcBridge.start()
    }
}
