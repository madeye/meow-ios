import MeowModels
import SwiftData
import SwiftUI

/// The whole tvOS app in one screen: title, connect button, subscription-URL
/// field, profile list.
///
/// A re-implementation rather than a reuse of `ContentView`: everything under
/// `App/Sources/Views` is iPhone-shaped (tab bar, sheets, swipe actions, the
/// QR camera scanner) and parts of it don't exist on tvOS at all, so this
/// target compiles the model + service layer only and puts this view on top.
/// The duplicated stage labels below are the cost of that split — keep them
/// in sync with `GlobalVpnSwitchBar`.
///
/// Styling note: no explicit `buttonStyle` anywhere. tvOS's default style is
/// the one that gets the focus lift and parallax, which is what a remote
/// control needs; `.bordered` / `.borderedProminent` only arrived in tvOS 17
/// and buy nothing here.
struct TVContentView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(SubscriptionService.self) private var subscriptionService
    /// Same ordering as the iOS Configs tab (`SubscriptionsView`).
    @Query(sort: \Profile.lastUpdated, order: .reverse) private var profiles: [Profile]

    @State private var subscriptionURL = ""
    @State private var isAdding = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            if let message = importError ?? vpnManager.lastError {
                errorBanner(message)
            }

            HStack(alignment: .top, spacing: 60) {
                connectionPanel
                subscriptionPanel
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("home.nav.title")
                .font(.largeTitle.weight(.bold))
            Text(profileName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("vpn.profile.name")
        }
    }

    private var connectionPanel: some View {
        VStack(spacing: 24) {
            Image(systemName: isConnected ? "power.circle.fill" : "power.circle")
                .font(.system(size: 96))
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            Text(stageBadgeText)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("vpn.status")

            Button(action: toggle) {
                Text(toggleTitle)
                    .frame(maxWidth: .infinity)
            }
            .disabled(toggleDisabled)
            .accessibilityIdentifier("vpn.toggle")
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
    }

    private var subscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("tv.subscription.section")
                .font(.title3.weight(.semibold))

            TextField("tv.subscription.field.url", text: $subscriptionURL)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .onSubmit(addSubscription)
                .accessibilityIdentifier("tv.subscription.url")

            Button(LocalizedStringKey(
                isAdding ? "subscriptions.add.button.adding" : "subscriptions.add.button.add",
            )) {
                addSubscription()
            }
            .disabled(isAdding || trimmedURL.isEmpty)
            .accessibilityIdentifier("tv.subscription.add")

            Divider()

            Text("tv.profiles.section")
                .font(.title3.weight(.semibold))

            if profiles.isEmpty {
                Text("tv.profiles.empty")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(40)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
    }

    private func profileRow(_ profile: Profile) -> some View {
        Button {
            select(profile)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: profile.isSelected ? "largecircle.fill.circle" : "circle")
                    .accessibilityHidden(true)
                Text(profile.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("tv.profile.row.\(profile.name)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 16) {
            Text(message)
                .font(.body)
                .foregroundStyle(.red)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button("home.error.dismiss") {
                importError = nil
                vpnManager.clearError()
            }
        }
        .padding(24)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("vpn.error.banner")
    }

    // MARK: - Derived state

    private var selectedProfile: Profile? {
        profiles.first(where: \.isSelected)
    }

    private var trimmedURL: String {
        subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileName: String {
        selectedProfile?.name ?? String(
            localized: "home.profile.none",
            comment: "Placeholder shown in profile-name slot when no subscription profile is selected",
        )
    }

    private var isConnected: Bool {
        vpnManager.stage == .connected
    }

    private var isInFlight: Bool {
        let stage = vpnManager.stage
        return stage == .preparing || stage == .connecting || stage == .stopping
    }

    private var stageBadgeText: LocalizedStringKey {
        switch vpnManager.stage {
        case .idle, .stopped, .error: "home.badge.disconnected"
        case .preparing: "home.badge.preparing"
        case .connecting: "home.badge.connecting"
        case .connected: "home.badge.connected"
        case .stopping: "home.badge.disconnecting"
        }
    }

    private var toggleTitle: LocalizedStringKey {
        switch vpnManager.stage {
        case .connected: "home.toggle.disconnect"
        case .preparing: "home.toggle.preparing"
        case .connecting: "home.toggle.connecting"
        case .stopping: "home.toggle.disconnecting"
        default: "home.toggle.connect"
        }
    }

    private var toggleDisabled: Bool {
        if isInFlight {
            return true
        }
        if isConnected {
            return false
        }
        return selectedProfile == nil
    }
}

// MARK: - Actions

private extension TVContentView {
    /// Same ordering as `GlobalVpnSwitchBar.toggle()`: the IPC intent is
    /// queued BEFORE the tunnel call, so the extension already knows which
    /// profile to load by the time it starts.
    func toggle() {
        if isConnected {
            ipcBridge.send(.stop)
            Task { await vpnManager.disconnect() }
        } else {
            ipcBridge.send(.start, profileID: selectedProfile?.id)
            Task { await vpnManager.connect() }
        }
    }

    func addSubscription() {
        let raw = trimmedURL
        // Same scheme allow-list as `SubscriptionDeepLink.parse` — only
        // http/https. A mistyped `file://` would otherwise turn the field
        // into an arbitrary local-file read.
        //
        // `http://` is deliberately let through here rather than rejected:
        // this target's Info.plist carries the same ATS settings as iOS, so
        // `SubscriptionService.rejectPlainHTTP` catches it one layer down and
        // surfaces the localized `subscriptions.error.plainHTTP` explanation.
        // Duplicating that check here would only replace a good message with
        // a worse one.
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            importError = String(localized: "tv.subscription.error.invalidURL")
            return
        }

        isAdding = true
        importError = nil
        Task {
            do {
                // iOS asks for a name in a second field; on a remote control
                // that's two keyboard sessions for a label, so derive it from
                // the host — the same fallback `SubscriptionDeepLink` uses for
                // a link with no `&name=`.
                let profile = try await subscriptionService.add(name: url.host ?? raw, url: raw)
                // Add-then-select: `add` only inserts, and a profile nobody
                // selected never reaches `config.yaml`, so the tunnel would
                // have nothing to start with.
                try subscriptionService.select(profile)
                reloadIfConnected(profile)
                subscriptionURL = ""
            } catch {
                importError = error.localizedDescription
            }
            isAdding = false
        }
    }

    func select(_ profile: Profile) {
        do {
            try subscriptionService.select(profile)
            reloadIfConnected(profile)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// `select` rewrites `config.yaml`, but a running engine has already read
    /// it. On iOS the escape hatch is Settings → "Reload engine config"; tvOS
    /// has no settings screen, so switching profiles mid-session would be a
    /// dead end. Send the same `.reload` intent inline instead — this is the
    /// one place the tvOS UI deliberately does more than its iOS counterpart.
    func reloadIfConnected(_ profile: Profile) {
        guard isConnected else { return }
        ipcBridge.send(.reload, profileID: profile.id)
    }
}
