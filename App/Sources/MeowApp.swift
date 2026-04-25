import FirebaseCore
import MeowModels
import SwiftData
import SwiftUI

@main
struct MeowApp: App {
    @State private var appModel = AppModel()

    init() {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
    }

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
