import MeowModels
import SwiftData
import SwiftUI

struct ProxyGroupsView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(MihomoAPI.self) private var mihomoAPI
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    @State private var groups: [ProxyGroupModel] = []
    @State private var expandedGroupID: String?
    @State private var inflightDelay: Set<String> = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let loadError {
                    Text(loadError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                if groups.isEmpty {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: "network.slash")
                                .foregroundStyle(.secondary)
                            Text(placeholderKey)
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
                            },
                        )
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("home.proxyGroups.header")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vpnManager.stage) { await refresh() }
        .refreshable { await refresh() }
    }

    private var placeholderKey: LocalizedStringKey {
        switch vpnManager.stage {
        case .connected: "home.proxyGroups.placeholder.connected"
        case .connecting: "home.proxyGroups.placeholder.connecting"
        default: "home.proxyGroups.placeholder.disconnected"
        }
    }
}

private extension ProxyGroupsView {
    func refresh() async {
        guard vpnManager.stage == .connected else {
            groups = []
            loadError = nil
            return
        }
        do {
            let resp = try await mihomoAPI.getProxies()
            groups = ProxyGroupModel.build(from: resp.proxies)
            loadError = nil
        } catch {
            loadError = String(
                localized: "home.error.apiUnavailable",
                comment: "Inline error shown in Proxy Groups header when mihomo API is not reachable",
            )
        }
    }

    func select(group: String, proxy: String) async {
        do {
            try await mihomoAPI.selectProxy(group: group, name: proxy)
            if let profile = selected.first {
                profile.selectedProxies[group] = proxy
                try? modelContext.save()
            }
            await refresh()
        } catch {
            loadError = String(
                localized: "home.error.selectFailed",
                comment: "Inline error shown in Proxy Groups header when selecting a proxy fails",
            )
        }
    }

    func ping(proxy: String) async {
        inflightDelay.insert(proxy)
        _ = try? await mihomoAPI.testDelay(
            proxy: proxy,
            url: "http://www.gstatic.com/generate_204",
        )
        await refresh()
        inflightDelay.remove(proxy)
    }
}

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
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(child.name) }
        .accessibilityIdentifier("home.proxy.\(group.id.identifierSlug).\(child.name.identifierSlug)")
    }

    private var groupSymbol: String {
        switch group.type {
        case "URLTest": "speedometer"
        case "Fallback": "arrow.uturn.right.circle"
        case "LoadBalance": "scale.3d"
        case "Relay": "arrow.triangle.turn.up.right.circle"
        default: "rectangle.stack"
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
        case ..<200: .green
        case 200 ..< 500: .yellow
        default: .red
        }
    }
}
