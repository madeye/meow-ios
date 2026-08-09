import SwiftData
import SwiftUI

/// tvOS entry point. Mirrors `App/Sources/MeowApp.swift` — same `AppModel`,
/// same service graph, same App Group container — and swaps only the root
/// view, because `App/Sources/Views` is not compiled into this target.
///
/// Injecting every service (not just the three `TVContentView` reads today)
/// keeps the two entry points diffable: a service added to `AppModel` shows
/// up here the same way it shows up on iOS.
@main
struct MeowTVApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            TVContentView()
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
