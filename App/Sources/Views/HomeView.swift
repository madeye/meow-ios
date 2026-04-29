import MeowModels
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(MihomoAPI.self) private var mihomoAPI
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    @State private var groupCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let message = vpnManager.lastError {
                    errorBanner(message)
                }
                primaryCard
                trafficRow
                proxyGroupsRow
                auxiliaryNavSection
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("home.nav.title")
        .task(id: vpnManager.stage) {
            await refreshGroupCount()
        }
        // The stage-keyed task above fires on the `.connected` edge and races
        // `AppModel.replaySelectedProxies`; the pre-replay fetch caches YAML
        // defaults and the UI never re-reads post-replay engine state. Keying
        // a second task on `replayGeneration` guarantees a re-fetch AFTER the
        // replay pass finishes (success, probe timeout, or no-op alike).
        .task(id: appModel.replayGeneration) {
            await refreshGroupCount()
        }
        .refreshable { await refreshGroupCount() }
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
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    StageDot(stage: vpnManager.stage)
                    Text(stageBadgeText)
                        .font(.headline)
                        .accessibilityIdentifier("home.badge.state")
                    Spacer()
                    Text(profileName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("home.profile.name")
                }

                HStack(spacing: 24) {
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

    // MARK: - Proxy groups

    private var proxyGroupsRow: some View {
        NavigationLink {
            ProxyGroupsView()
        } label: {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(Color.accentColor)
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
        VStack(spacing: 10) {
            NavRow(
                title: "home.nav.connections",
                systemImage: "chevron.right.square",
                identifier: "home.nav.connections",
            ) { ConnectionsView() }

            NavRow(
                title: "home.nav.rules",
                systemImage: "arrow.triangle.branch",
                identifier: "home.nav.rules",
            ) { RulesView() }

            NavRow(
                title: "home.nav.providers",
                systemImage: "tray.full",
                identifier: "home.nav.providers",
            ) { ProvidersView() }

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
        vpnManager.stage == .connecting || vpnManager.stage == .stopping
    }

    /// PRD §4.3 + team-lead spec: lowercase ASCII, exactly one of
    /// `disconnected`, `connecting`, `connected`, `disconnecting`. QA's
    /// harness pins on this — don't localise, don't title-case.
    private var stageBadgeText: String {
        switch vpnManager.stage {
        case .idle, .stopped, .error: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .stopping: "disconnecting"
        }
    }

    private var toggleTitle: LocalizedStringKey {
        switch vpnManager.stage {
        case .connected: "home.toggle.disconnect"
        case .connecting: "home.toggle.connecting"
        case .stopping: "home.toggle.disconnecting"
        default: "home.toggle.connect"
        }
    }

    private var toggleTint: Color {
        switch vpnManager.stage {
        case .connected: .red
        case .connecting, .stopping: .orange
        case .error: .red
        default: .accentColor
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

    func refreshGroupCount() async {
        guard vpnManager.stage == .connected else {
            groupCount = 0
            return
        }
        do {
            let resp = try await mihomoAPI.getProxies()
            groupCount = ProxyGroupModel.build(from: resp.proxies).count
        } catch {
            groupCount = 0
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
        case .connecting, .stopping: .yellow
        case .connected: .green
        case .error: .red
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
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
