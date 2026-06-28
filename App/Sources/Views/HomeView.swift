import MeowModels
import SwiftData
import SwiftUI

struct HomeView: View {
    var body: some View {
        ScrollView {
            EngineOverviewSection()
                .padding(16)
        }
        .background(AppTheme.screenBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle("home.nav.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EngineOverviewSection: View {
    let showsStatusSummary: Bool

    @Environment(AppModel.self) private var appModel
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(MeowAPI.self) private var meowAPI
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    @State private var auxiliaryDestination: EngineAuxiliaryDestination?
    @State private var routeMode: RouteMode = .rule

    init(showsStatusSummary: Bool = true) {
        self.showsStatusSummary = showsStatusSummary
    }

    var body: some View {
        VStack(spacing: 16) {
            if showsStatusSummary {
                primaryCard
                trafficRow
            }
            routeModeRow
            auxiliaryNavSection
        }
        .task(id: vpnManager.stage) {
            await refreshRouteMode()
        }
        .task(id: appModel.replayGeneration) {
            await refreshRouteMode()
        }
        .refreshable {
            await refreshRouteMode()
        }
    }

    // MARK: - Primary card

    private var primaryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    VpnStatusGlyph(stage: vpnManager.stage)
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
            }
        }
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
                    .accessibilityHidden(true)
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

    // MARK: - Auxiliary nav

    private var auxiliaryNavSection: some View {
        GlassCard {
            VStack(spacing: 0) {
                NavRow(
                    title: "home.nav.connections",
                    systemImage: "chevron.right.square",
                    identifier: "home.nav.connections",
                ) { auxiliaryDestination = .connections }

                Divider().padding(.leading, 42)

                NavRow(
                    title: "home.nav.rules",
                    systemImage: "arrow.triangle.branch",
                    identifier: "home.nav.rules",
                ) { auxiliaryDestination = .rules }

                Divider().padding(.leading, 42)

                NavRow(
                    title: "home.nav.providers",
                    systemImage: "tray.full",
                    identifier: "home.nav.providers",
                ) { auxiliaryDestination = .providers }

                Divider().padding(.leading, 42)

                NavRow(
                    title: "home.nav.diagnostics",
                    systemImage: "stethoscope",
                    identifier: "home.nav.diagnostics",
                ) { auxiliaryDestination = .diagnostics }
            }
        }
        .navigationDestination(item: $auxiliaryDestination) { destination in
            switch destination {
            case .connections:
                ConnectionsView()
            case .rules:
                RulesView()
            case .providers:
                ProvidersView()
            case .diagnostics:
                DiagnosticsPanelView()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("home.nav.diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Derived state

    private var profileName: String {
        selected.first?.name ?? String(
            localized: "home.profile.none",
            comment: "Placeholder shown in profile-name slot when no subscription profile is selected",
        )
    }

    private var isConnected: Bool {
        vpnManager.stage == .connected
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
}

// MARK: - Actions

// Methods split into an extension so swiftlint's `type_body_length` counts
// only the declarative surface (stored state + subviews) — the action layer
// is wiring between the view and the engine and reads as a separate concern.

private extension EngineOverviewSection {
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

private enum EngineAuxiliaryDestination: Identifiable {
    case connections
    case rules
    case providers
    case diagnostics

    var id: Self {
        self
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(count)"))
        .accessibilityAddTraits(.updatesFrequently)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct NavRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(AppTheme.accent.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
