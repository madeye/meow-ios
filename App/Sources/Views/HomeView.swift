import SwiftUI
import SwiftData
import MeowModels

struct HomeView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(MihomoAPI.self) private var mihomoAPI
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    @State private var groups: [ProxyGroupModel] = []
    @State private var expandedGroupID: String? = nil
    @State private var inflightDelay: Set<String> = []
    @State private var groupsLoadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                primaryCard
                trafficRow
                proxyGroupsSection
                auxiliaryNavSection
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("meow")
        .task(id: vpnManager.stage) {
            await refreshGroupsIfConnected()
        }
        .refreshable { await refreshGroupsIfConnected() }
    }

    // MARK: - Primary card

    @ViewBuilder private var primaryCard: some View {
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
                        label: "Ingress"
                    )
                    PacketStat(
                        systemImage: "arrow.up.to.line.square",
                        count: ipcBridge.currentTraffic.egressPackets,
                        label: "Egress"
                    )
                    Spacer()
                }

                vpnToggle
            }
        }
    }

    @ViewBuilder private var vpnToggle: some View {
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

    @ViewBuilder private var trafficRow: some View {
        HStack(spacing: 12) {
            TrafficTile(
                title: "Upload",
                bytes: ipcBridge.currentTraffic.uploadBytes,
                rate: ipcBridge.currentTraffic.uploadRate,
                systemImage: "arrow.up"
            )
            TrafficTile(
                title: "Download",
                bytes: ipcBridge.currentTraffic.downloadBytes,
                rate: ipcBridge.currentTraffic.downloadRate,
                systemImage: "arrow.down"
            )
        }
    }

    // MARK: - Proxy groups

    @ViewBuilder private var proxyGroupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proxy Groups")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer()
                if let err = groupsLoadError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)

            if groups.isEmpty {
                GlassCard {
                    HStack(spacing: 8) {
                        Image(systemName: "network.slash")
                            .foregroundStyle(.secondary)
                        Text(placeholderText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                ForEach(groups) { group in
                    ProxyGroupCard(
                        group: group,
                        isExpanded: expandedGroupID == group.id,
                        inflight: inflightDelay,
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedGroupID = expandedGroupID == group.id ? nil : group.id
                            }
                        },
                        onSelect: { proxy in
                            Task { await select(group: group.name, proxy: proxy) }
                        },
                        onPing: { proxy in
                            Task { await ping(proxy: proxy) }
                        }
                    )
                }
            }
        }
    }

    private var placeholderText: String {
        switch vpnManager.stage {
        case .connected: return "Loading groups…"
        case .connecting: return "Connecting — groups appear when the engine is up."
        default: return "Connect to populate available groups."
        }
    }

    // MARK: - Auxiliary nav

    @ViewBuilder private var auxiliaryNavSection: some View {
        VStack(spacing: 10) {
            NavRow(
                title: "Connections",
                systemImage: "chevron.right.square",
                identifier: "home.nav.connections"
            ) { ConnectionsView() }

            NavRow(
                title: "Rules",
                systemImage: "arrow.triangle.branch",
                identifier: "home.nav.rules"
            ) { RulesView() }

            NavRow(
                title: "Providers",
                systemImage: "tray.full",
                identifier: "home.nav.providers"
            ) { ProvidersView() }

            NavRow(
                title: "Diagnostics",
                systemImage: "stethoscope",
                identifier: "home.nav.diagnostics"
            ) {
                DiagnosticsPanelView()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Derived state

    private var profileName: String { selected.first?.name ?? "No Profile" }

    private var isConnected: Bool { vpnManager.stage == .connected }

    private var isInFlight: Bool {
        vpnManager.stage == .connecting || vpnManager.stage == .stopping
    }

    /// PRD §4.3 + team-lead spec: lowercase ASCII, exactly one of
    /// `disconnected`, `connecting`, `connected`, `disconnecting`. QA's
    /// harness pins on this — don't localise, don't title-case.
    private var stageBadgeText: String {
        switch vpnManager.stage {
        case .idle, .stopped, .error: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .stopping: return "disconnecting"
        }
    }

    private var toggleTitle: String {
        switch vpnManager.stage {
        case .connected: return "Disconnect"
        case .connecting: return "Connecting…"
        case .stopping: return "Disconnecting…"
        default: return "Connect"
        }
    }

    private var toggleTint: Color {
        switch vpnManager.stage {
        case .connected: return .red
        case .connecting, .stopping: return .orange
        case .error: return .red
        default: return .accentColor
        }
    }

    private var toggleDisabled: Bool {
        if isInFlight { return true }
        if isConnected { return false }
        return selected.first == nil
    }

    // MARK: - Actions

    private func toggle() {
        if isConnected {
            ipcBridge.send(.stop)
            vpnManager.disconnect()
        } else {
            ipcBridge.send(.start, profileID: selected.first?.id)
            Task { await vpnManager.connect() }
        }
    }

    private func refreshGroupsIfConnected() async {
        guard vpnManager.stage == .connected else {
            groups = []
            groupsLoadError = nil
            return
        }
        do {
            let resp = try await mihomoAPI.getProxies()
            groups = ProxyGroupModel.build(from: resp.proxies)
            groupsLoadError = nil
        } catch {
            groupsLoadError = "API unavailable"
        }
    }

    private func select(group: String, proxy: String) async {
        do {
            try await mihomoAPI.selectProxy(group: group, name: proxy)
            await refreshGroupsIfConnected()
        } catch {
            groupsLoadError = "select failed"
        }
    }

    private func ping(proxy: String) async {
        inflightDelay.insert(proxy)
        _ = try? await mihomoAPI.testDelay(
            proxy: proxy,
            url: "http://www.gstatic.com/generate_204"
        )
        await refreshGroupsIfConnected()
        inflightDelay.remove(proxy)
    }
}

// MARK: - Proxy group model

struct ProxyGroupModel: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let now: String?
    let children: [Child]

    struct Child: Identifiable, Equatable {
        let id: String
        let name: String
        let type: String
        let delay: Int?
    }

    /// Flatten the mihomo `/proxies` response into the subset of proxy groups
    /// the user can interact with. `GLOBAL` is hidden because it's the
    /// top-level aggregator, not a user-facing selector; direct/reject are
    /// leaf proxies, not groups.
    static func build(from dict: [String: Proxy]) -> [ProxyGroupModel] {
        let selectable: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
        return dict.values
            .filter { selectable.contains($0.type) && $0.all != nil && $0.name != "GLOBAL" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { group in
                let children = (group.all ?? []).compactMap { childName -> Child? in
                    guard let p = dict[childName] else { return nil }
                    return Child(
                        id: childName,
                        name: p.name,
                        type: p.type,
                        delay: p.history?.last?.delay
                    )
                }
                return ProxyGroupModel(
                    id: group.name,
                    name: group.name,
                    type: group.type,
                    now: group.now,
                    children: children
                )
            }
    }
}

// MARK: - Subviews

private struct ProxyGroupCard: View {
    let group: ProxyGroupModel
    let isExpanded: Bool
    let inflight: Set<String>
    var onToggleExpand: () -> Void
    var onSelect: (String) -> Void
    var onPing: (String) -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 10) {
                        Image(systemName: groupSymbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(group.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let now = group.now {
                            Text(now)
                                .font(.subheadline)
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                    VStack(spacing: 8) {
                        ForEach(group.children) { child in
                            proxyRow(child)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("home.group.\(group.id.identifierSlug)")
    }

    @ViewBuilder
    private func proxyRow(_ child: ProxyGroupModel.Child) -> some View {
        HStack(spacing: 10) {
            Image(systemName: child.name == group.now ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(child.name == group.now ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(child.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            DelayBadge(delay: child.delay, isLoading: inflight.contains(child.name))
                .onTapGesture { onPing(child.name) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(child.name) }
        .accessibilityIdentifier("home.proxy.\(group.id.identifierSlug).\(child.name.identifierSlug)")
    }

    private var groupSymbol: String {
        switch group.type {
        case "URLTest": return "speedometer"
        case "Fallback": return "arrow.uturn.right.circle"
        case "LoadBalance": return "scale.3d"
        case "Relay": return "arrow.triangle.turn.up.right.circle"
        default: return "rectangle.stack"
        }
    }
}

private struct DelayBadge: View {
    let delay: Int?
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if let delay, delay > 0 {
                Text("\(delay) ms")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tint(for: delay).opacity(0.18), in: Capsule())
                    .foregroundStyle(tint(for: delay))
            } else {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 56, alignment: .trailing)
    }

    private func tint(for delay: Int) -> Color {
        switch delay {
        case ..<200: return .green
        case 200..<500: return .yellow
        default: return .red
        }
    }
}

private struct PacketStat: View {
    let systemImage: String
    let count: Int64
    let label: String

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
        case .idle, .stopped: return .secondary
        case .connecting, .stopping: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
}

private struct TrafficTile: View {
    let title: String
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
                Text("Total " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NavRow<Destination: View>: View {
    let title: String
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

// MARK: - Slug helper

private extension String {
    /// Identifier-safe slug for XCUITest `accessibilityIdentifier`. Lowercases
    /// and collapses anything outside `[a-z0-9]` to single `-` separators. QA's
    /// harness pins on deterministic IDs, so this must stay pure — no
    /// locale-aware casing, no Unicode normalisation beyond ASCII.
    var identifierSlug: String {
        var out = ""
        var trailingDash = true
        for scalar in unicodeScalars {
            let v = scalar.value
            let isLower = v >= 0x61 && v <= 0x7A
            let isUpper = v >= 0x41 && v <= 0x5A
            let isDigit = v >= 0x30 && v <= 0x39
            if isDigit || isLower {
                out.append(Character(scalar))
                trailingDash = false
            } else if isUpper {
                out.append(Character(Unicode.Scalar(v + 0x20)!))
                trailingDash = false
            } else if !trailingDash {
                out.append("-")
                trailingDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "_" : out
    }
}
