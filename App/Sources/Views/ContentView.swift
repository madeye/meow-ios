import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showDiagnostics = false

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
        .onOpenURL { url in
            if url.scheme == "meow" && url.host == "diagnostics" {
                showDiagnostics = true
            }
        }
        .fullScreenCover(isPresented: $showDiagnostics) {
            NavigationStack {
                DiagnosticsPanelView()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showDiagnostics = false }
                        }
                    }
            }
        }
    }
}
