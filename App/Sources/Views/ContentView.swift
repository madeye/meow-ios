import SwiftUI

/// Top-level tabs. Raw values double as the `-screenshotTab <value>` launch
/// argument used by the App Store screenshot capture (honored only in UI-test
/// builds — see `initialTab`).
enum ContentTab: String {
    case subscriptions, proxyGroups, traffic, logs, settings
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SubscriptionService.self) private var subscriptionService
    @State private var showDiagnostics = false
    @State private var importError: String?
    @State private var selectedTab: ContentTab = initialTab()

    var body: some View {
        VStack(spacing: 0) {
            GlobalVpnSwitchBar()

            TabView(selection: $selectedTab) {
                NavigationStack { SubscriptionsView() }
                    .tabItem { Label("tabs.subscriptions", systemImage: "text.document.fill") }
                    .accessibilityIdentifier("Subscriptions")
                    .tag(ContentTab.subscriptions)
                NavigationStack { ProxyGroupsView() }
                    .tabItem { Label("tabs.proxyGroups", systemImage: "rectangle.stack.fill") }
                    .accessibilityIdentifier("Proxy Groups")
                    .tag(ContentTab.proxyGroups)
                NavigationStack { TrafficView() }
                    .tabItem { Label("tabs.traffic", systemImage: "chart.bar.fill") }
                    .accessibilityIdentifier("Traffic")
                    .tag(ContentTab.traffic)
                NavigationStack { LogsView() }
                    .tabItem { Label("tabs.logs", systemImage: "list.bullet.rectangle.fill") }
                    .accessibilityIdentifier("Logs")
                    .tag(ContentTab.logs)
                NavigationStack { SettingsView() }
                    .tabItem { Label("tabs.settings", systemImage: "gearshape.fill") }
                    .accessibilityIdentifier("Settings")
                    .tag(ContentTab.settings)
            }
        }
        .background(AppTheme.screenBackground)
        .tint(AppTheme.accent)
        .preferredColorScheme(.light)
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
                                .accessibilityLabel(String(localized: "a11y.content.diagnostics.close"))
                                .accessibilityHint(String(localized: "a11y.content.diagnostics.closeHint"))
                        }
                    }
            }
            .onAppear {
                AccessibilityNotification.ScreenChanged().post()
            }
        }
        .alert("subscriptions.import.errorTitle", isPresented: .constant(importError != nil)) {
            Button("common.ok") { importError = nil }
                .accessibilityLabel(String(localized: "a11y.common.dismissAlert"))
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: importError) { _, newError in
            if newError != nil {
                AccessibilityNotification.Announcement(String(localized: "subscriptions.import.errorTitle")).post()
            }
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

/// Initial tab for the screenshot harness. Only honors `-screenshotTab <tab>`
/// when launched with `-UITests`, so production launches start on Subscriptions.
private func initialTab() -> ContentTab {
    let argv = ProcessInfo.processInfo.arguments
    guard argv.contains("-UITests"),
          let i = argv.firstIndex(of: "-screenshotTab"), i + 1 < argv.count
    else { return .subscriptions }

    let rawTab = argv[i + 1]
    // Historical screenshot scripts used `home`; Subscriptions is now the
    // home tab surface, so keep old invocations useful.
    if rawTab == "home" { return .subscriptions }
    return ContentTab(rawValue: rawTab) ?? .subscriptions
}
