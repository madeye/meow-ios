import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SubscriptionService.self) private var subscriptionService
    @State private var showDiagnostics = false
    @State private var importError: String?

    var body: some View {
        TabView {
            Tab("tabs.home", systemImage: "house.fill") {
                NavigationStack { HomeView() }
            }
            Tab("tabs.subscriptions", systemImage: "text.document.fill") {
                NavigationStack { SubscriptionsView() }
            }
            Tab("tabs.traffic", systemImage: "chart.bar.fill") {
                NavigationStack { TrafficView() }
            }
            Tab("tabs.logs", systemImage: "list.bullet.rectangle.fill") {
                NavigationStack { LogsView() }
            }
            Tab("tabs.settings", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            }
        }
        .onOpenURL { url in
            if url.scheme == "meow", url.host == "diagnostics" {
                showDiagnostics = true
                return
            }
            if let link = SubscriptionDeepLink.parse(url) {
                Task { await handleSubscriptionImport(link) }
            }
        }
        .fullScreenCover(isPresented: $showDiagnostics) {
            NavigationStack {
                DiagnosticsPanelView()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("content.diagnostics.nav.title")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.close") { showDiagnostics = false }
                        }
                    }
            }
        }
        .alert("subscriptions.import.errorTitle", isPresented: .constant(importError != nil)) {
            Button("common.ok") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    @MainActor
    private func handleSubscriptionImport(_ link: SubscriptionDeepLink) async {
        do {
            let profile = try await subscriptionService.add(
                name: link.name,
                url: link.subscriptionURL.absoluteString,
            )
            if link.autoSelect {
                try subscriptionService.select(profile)
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}
