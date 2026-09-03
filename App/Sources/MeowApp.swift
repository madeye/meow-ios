import SwiftData
import SwiftUI

@main
struct MeowApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            // Only `.background` stops the auto-update timer. `.inactive`
            // fires for transient interruptions (notification centre, app
            // switcher preview) where tearing the timer down and rebuilding
            // it would run a due-check on every glance at the app.
            switch phase {
            case .active:
                appModel.profileAutoUpdater.start()
            case .background:
                appModel.profileAutoUpdater.stop()
            default:
                break
            }
        }
    }
}
