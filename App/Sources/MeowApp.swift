import MeowModels
import SwiftData
import SwiftUI

@main
struct MeowApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appModel.vpnManager)
                .environment(appModel.mihomoAPI)
                .environment(appModel.subscriptionService)
                .environment(appModel.ipcBridge)
                .task { await appModel.bootstrap() }
        }
        .modelContainer(AppModelContainer.shared.container)
    }
}
