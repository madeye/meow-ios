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
                .environment(appModel.meowAPI)
                .environment(appModel.subscriptionService)
                .environment(appModel.ipcBridge)
                .environment(appModel.utilityTrafficChart)
                .environment(appModel.utilityLogs)
                .task { await appModel.bootstrap() }
        }
        .modelContainer(AppModelContainer.shared.container)
    }
}
