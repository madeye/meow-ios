import SwiftData
import SwiftUI

/// Top-level tabs. Raw values double as the `-screenshotTab <value>` launch
/// argument used by the App Store screenshot capture (honored only in UI-test
/// builds — see `initialTab`).
enum ContentTab: String {
    case subscriptions, proxyGroups, utility, settings
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SubscriptionService.self) private var subscriptionService
    @Query private var profiles: [Profile]
    @State private var showDiagnostics = false
    @State private var importError: String?
    @State private var selectedTab: ContentTab = initialTab()
    /// The confirmation currently on screen for a `meow://connect` deep
    /// link, if any. A second deep link arriving while one is already
    /// pending replaces it rather than stacking a second sheet (issue #293).
    @State private var pendingDeepLinkConfirmation: DeepLinkImportConfirmation?
    @State private var importingDeepLinkURLs: Set<String> = []

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
                NavigationStack { UtilityView() }
                    .tabItem { Label("tabs.utility", systemImage: "wrench.and.screwdriver.fill") }
                    .accessibilityIdentifier("Utility")
                    .tag(ContentTab.utility)
                NavigationStack { SettingsView() }
                    .tabItem { Label("tabs.settings", systemImage: "gearshape.fill") }
                    .accessibilityIdentifier("Settings")
                    .tag(ContentTab.settings)
            }
        }
        .background(AppTheme.screenBackground)
        .tint(AppTheme.accent)
        .onOpenURL { url in
            if url.scheme == "meow", url.host == "diagnostics" {
                showDiagnostics = true
                return
            }
            if let link = SubscriptionDeepLink.parse(url) {
                // Never fetch or import here — only build the confirmation.
                // Replacing any already-pending confirmation (rather than
                // stacking a second sheet) keeps a burst of replayed deep
                // links from crashing or queuing indefinitely.
                pendingDeepLinkConfirmation = DeepLinkImportConfirmation.make(
                    for: link,
                    existingProfiles: profiles.map { ($0.id, $0.url) },
                )
            }
        }
        .sheet(item: $pendingDeepLinkConfirmation) { confirmation in
            DeepLinkConfirmationSheet(confirmation: confirmation) { action in
                Task { await handleDeepLinkConfirmation(confirmation, action: action) }
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
    private func handleDeepLinkConfirmation(
        _ confirmation: DeepLinkImportConfirmation,
        action: DeepLinkConfirmationAction,
    ) async {
        let url = confirmation.subscriptionURL.absoluteString
        guard !importingDeepLinkURLs.contains(url) else { return }
        importingDeepLinkURLs.insert(url)
        defer { importingDeepLinkURLs.remove(url) }

        let coordinator = DeepLinkImportCoordinator(subscriptionService: subscriptionService)
        let existingProfile = confirmation.existingProfileID.flatMap { id in
            profiles.first { $0.id == id }
        }
        do {
            try await coordinator.resolve(confirmation, action: action, existingProfile: existingProfile)
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
    // Traffic/Logs moved under Utility; keep old screenshot tab names working.
    if rawTab == "traffic" || rawTab == "logs" || rawTab == "dns" { return .utility }
    return ContentTab(rawValue: rawTab) ?? .subscriptions
}
