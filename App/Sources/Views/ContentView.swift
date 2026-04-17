import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack { HomeView() }
            }
            Tab("Subscriptions", systemImage: "text.document.fill") {
                NavigationStack { SubscriptionsView() }
            }
            Tab("Traffic", systemImage: "chart.bar.fill") {
                NavigationStack { TrafficView() }
            }
            Tab("Logs", systemImage: "list.bullet.rectangle.fill") {
                NavigationStack { LogsView() }
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            }
        }
    }
}
