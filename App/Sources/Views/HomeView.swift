import MeowModels
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(MeowAPI.self) private var meowAPI
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    @State private var groupCount: Int = 0
    @State private var routeMode: RouteMode = .rule

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let message = vpnManager.lastError {
                    errorBanner(message)
                }
                primaryCard
                trafficRow
                routeModeRow
                proxyGroupsRow
                auxiliaryNavSection
            }
            .padding(16)
        }
        .background(AppTheme.screenBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle("home.nav.title")
        .task(id: vpnManager.stage) {
            await refreshGroupCount()
            await refreshRouteMode()
        }
        // The stage-keyed task above fires on the `.connected` edge and races
        // `AppModel.replaySelectedProxies`; the pre-replay fetch caches YAML
        // defaults and the UI never re-reads post-replay engine state. Keying
        // a second task on `replayGeneration` guarantees a re-fetch AFTER the
        // replay pass finishes (success, probe timeout, or no-op alike).
        .task(id: appModel.replayGeneration) {
            await refreshGroupCount()
            await refreshRouteMode()
        }
        .refreshable {
            await refreshGroupCount()
            await refreshRouteMode()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("home.error.tunnelFailed.title")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                vpnManager.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("home.error.dismiss")
            .accessibilityIdentifier("home.error.dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("home.error.banner")
    }

    // MARK: - Primary card

    private var primaryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    StatusGlyph(stage: vpnManager.stage)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stageBadgeText)
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("home.badge.state")
                        Text(profileName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("home.profile.name")
                    }
                    Spacer()
                }

                HStack(spacing: 18) {
                    PacketStat(
                        systemImage: "arrow.down.to.line.square",
                        count: ipcBridge.currentTraffic.ingressPackets,
                        label: "home.packet.ingress",
                    )
                    PacketStat(
                        systemImage: "arrow.up.to.line.square",
                        count: ipcBridge.currentTraffic.egressPackets,
                        label: "home.packet.egress",
                    )
                    Spacer()
                }

                vpnToggle
            }
        }
    }

    private var vpnToggle: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                if isInFlight {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Image(systemName: isConnected ? "power.circle.fill" : "power.circle")
                    .imageScale(.large)
                Text(toggleTitle)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(toggleTint)
        .disabled(toggleDisabled)
        .accessibilityIdentifier("home.toggle.vpn")
    }

    // MARK: - Traffic row

    private var trafficRow: some View {
        HStack(spacing: 12) {
            TrafficTile(
                title: "home.traffic.upload",
                bytes: ipcBridge.currentTraffic.uploadBytes,
                rate: ipcBridge.currentTraffic.uploadRate,
                systemImage: "arrow.up",
            )
            TrafficTile(
                title: "home.traffic.download",
                bytes: ipcBridge.currentTraffic.downloadBytes,
                rate: ipcBridge.currentTraffic.downloadRate,
                systemImage: "arrow.down",
            )
        }
    }

    // MARK: - Route mode

    /// Custom binding so the picker's set-path issues the PATCH and the
    /// get-path stays in sync with the @State value. Setting `routeMode`
    /// directly via `.onChange` re-triggered the PATCH whenever
    /// `refreshRouteMode()` synced from the server.
    private var routeModeBinding: Binding<RouteMode> {
        Binding(
            get: { routeMode },
            set: { new in
                guard new != routeMode else { return }
                routeMode = new
                Task { await applyRouteMode(new) }
            },
        )
    }

    private var routeModeRow: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)
                Text("home.routeMode.title")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Picker("home.routeMode.title", selection: routeModeBinding) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!isConnected)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("home.routeMode.picker")
            }
        }
    }

    // MARK: - Proxy groups

    private var proxyGroupsRow: some View {
        NavigationLink {
            ProxyGroupsView()
        } label: {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 24)
                    Text("home.proxyGroups.header")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(groupCountText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.proxyGroups.count")
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(groupCount == 0)
        .accessibilityIdentifier("home.nav.proxyGroups")
    }

    private var groupCountText: String {
        groupCount == 0 ? "—" : "\(groupCount)"
    }

    // MARK: - Auxiliary nav

    private var auxiliaryNavSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                NavRow(
                    title: "home.nav.connections",
                    systemImage: "chevron.right.square",
                    identifier: "home.nav.connections",
                ) { ConnectionsView() }

                Divider().padding(.leading, 42)

                NavRow(
                    title: "home.nav.rules",
                    systemImage: "arrow.triangle.branch",
                    identifier: "home.nav.rules",
                ) { RulesView() }

                Divider().padding(.leading, 42)

                NavRow(
                    title: "home.nav.providers",
                    systemImage: "tray.full",
                    identifier: "home.nav.providers",
                ) { ProvidersView() }

                Divider().padding(.leading, 42)

                NavRow(
                    title: "home.nav.diagnostics",
                    systemImage: "stethoscope",
                    identifier: "home.nav.diagnostics",
                ) {
                    DiagnosticsPanelView()
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("home.nav.diagnostics")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    // MARK: - Derived state

    private var profileName: String {
        selected.first?.name ?? String(
            localized: "home.profile.none",
            comment: "Placeholder shown in profile-name slot on Home when no subscription profile is selected",
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

    private var toggleTint: Color {
        switch vpnManager.stage {
        case .connected: AppTheme.danger
        case .preparing, .connecting, .stopping: AppTheme.warning
        case .error: AppTheme.danger
        default: AppTheme.accent
        }
    }

    private var toggleDisabled: Bool {
        if isInFlight { return true }
        if isConnected { return false }
        return selected.first == nil
    }
}

// MARK: - Actions

// Methods split into an extension so swiftlint's `type_body_length` counts
// only the declarative surface (stored state + subviews) — the action layer
// is wiring between the view and the engine and reads as a separate concern.

private extension HomeView {
    func toggle() {
        if isConnected {
            ipcBridge.send(.stop)
            Task { await vpnManager.disconnect() }
        } else {
            ipcBridge.send(.start, profileID: selected.first?.id)
            Task { await vpnManager.connect() }
        }
    }

    func refreshRouteMode() async {
        guard vpnManager.stage == .connected else { return }
        do {
            let resp = try await meowAPI.getConfigs()
            if let mode = RouteMode(wire: resp.mode) {
                routeMode = mode
            }
        } catch {
            // Leave the picker at its last known value — re-syncs on next refresh.
        }
    }

    func applyRouteMode(_ mode: RouteMode) async {
        guard vpnManager.stage == .connected else { return }
        do {
            try await meowAPI.setMode(mode.wire)
        } catch {
            // Re-fetch to revert the segmented control if the engine rejected it.
            await refreshRouteMode()
        }
    }

    func refreshGroupCount() async {
        guard vpnManager.stage == .connected else {
            groupCount = 0
            return
        }
        do {
            let resp = try await meowAPI.getProxies()
            groupCount = ProxyGroupModel.build(from: resp.proxies).count
        } catch {
            groupCount = 0
        }
    }
}

// MARK: - Route mode

enum RouteMode: String, CaseIterable, Identifiable {
    case rule
    case all
    case direct

    var id: String {
        rawValue
    }

    /// Wire value sent to meow's `PATCH /configs`. Meow calls the
    /// "send everything through proxies" mode `global`; the UI uses `All`
    /// to match how users describe it in this app.
    var wire: String {
        switch self {
        case .rule: "rule"
        case .all: "global"
        case .direct: "direct"
        }
    }

    init?(wire: String) {
        switch wire.lowercased() {
        case "rule": self = .rule
        case "global": self = .all
        case "direct": self = .direct
        default: return nil
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .rule: "home.routeMode.rule"
        case .all: "home.routeMode.all"
        case .direct: "home.routeMode.direct"
        }
    }
}

// MARK: - Subviews

private struct PacketStat: View {
    let systemImage: String
    let count: Int64
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StageDot: View {
    let stage: VpnStage

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.6), radius: 6)
    }

    private var color: Color {
        switch stage {
        case .idle, .stopped: .secondary
        case .preparing, .connecting, .stopping: AppTheme.warning
        case .connected: AppTheme.connected
        case .error: AppTheme.danger
        }
    }
}

private struct StatusGlyph: View {
    let stage: VpnStage

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.iconBackground)
                .frame(width: 54, height: 54)
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
        .overlay(alignment: .bottomTrailing) {
            StageDot(stage: stage)
                .background(.background, in: Circle())
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch stage {
        case .connected: "checkmark.shield.fill"
        case .preparing, .connecting, .stopping: "bolt.horizontal.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        default: "shield"
        }
    }

    private var color: Color {
        switch stage {
        case .connected: AppTheme.connected
        case .preparing, .connecting, .stopping: AppTheme.warning
        case .error: AppTheme.danger
        default: AppTheme.accent
        }
    }
}

private struct TrafficTile: View {
    let title: LocalizedStringKey
    let bytes: Int64
    let rate: Int64
    let systemImage: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: rate, countStyle: .binary) + "/s")
                    .font(.title3.bold())
                    .monospacedDigit()
                Text(
                    "home.traffic.total \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))",
                    comment: "Total bytes label under the rate display; %@ = formatted byte count",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NavRow<Destination: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let identifier: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(AppTheme.accent.opacity(0.10), in: Circle())
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
