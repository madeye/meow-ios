import MeowModels
import SwiftData
import SwiftUI

struct ProxyGroupsView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(MeowAPI.self) private var meowAPI
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .foregroundStyle(AppTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                if groups.isEmpty {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: "network.slash")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
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
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
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
        .background(AppTheme.screenBackground)
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
            let resp = try await meowAPI.getProxies()
            groups = ProxyGroupModel.build(from: resp.proxies)
            loadError = nil
        } catch {
            loadError = String(
                localized: "home.error.apiUnavailable",
                comment: "Inline error shown in Proxy Groups header when meow API is not reachable",
            )
        }
    }

    func select(group: String, proxy: String) async {
        do {
            try await meowAPI.selectProxy(group: group, name: proxy)
            if let profile = selected.first {
                profile.selectedProxies[group] = proxy
                try? modelContext.save()
            }
            await refresh()
        } catch {
            // Surface the underlying reason — `MeowAPIError.proxyControl`
            // carries the sanitized message from `meow_core_last_error`
            // (e.g. "engine not running", "'<name>' is not a member of
            // '<group>'", "'<group>' is not a select-type group"), and
            // HTTP-fallback failures carry a status code. Hiding it
            // behind a generic localized string makes "select failed"
            // un-debuggable from the device UI alone.
            let prefix = String(
                localized: "home.error.selectFailed",
                comment: "Inline error shown in Proxy Groups header when selecting a proxy fails",
            )
            loadError = "\(prefix): \(Self.describe(error))"
        }
    }

    /// Compact, user-facing description of the API error. The reasons
    /// are already sanitized at the FFI boundary, so they're safe to
    /// show verbatim.
    private static func describe(_ error: any Error) -> String {
        if let api = error as? MeowAPIError {
            switch api {
            case let .proxyControl(reason): return reason
            case let .http(status): return "HTTP \(status)"
            case .malformed: return "malformed response"
            }
        }
        return error.localizedDescription
    }

    func ping(proxy: String) async {
        inflightDelay.insert(proxy)
        _ = try? await meowAPI.testDelay(
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
                            .accessibilityHidden(true)
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
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded
                    ? Text("a11y.proxyGroups.group.expanded")
                    : Text("a11y.proxyGroups.group.collapsed"))
                .accessibilityHint(Text("a11y.proxyGroups.group.hint"))

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
                .foregroundStyle(child.name == group.now ? AppTheme.accent : .secondary)
                .frame(width: 20)
            Text(child.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            DelayBadge(delay: child.delay, isLoading: inflight.contains(child.name))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { onPing(child.name) }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(child.name) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(child.name)
        .accessibilityValue(delayValue(for: child))
        .accessibilityAddTraits(child.name == group.now ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("a11y.proxyGroups.proxy.hint"))
        .accessibilityAction(named: Text("a11y.proxyGroups.proxy.action.ping")) { onPing(child.name) }
        .accessibilityIdentifier("home.proxy.\(group.id.identifierSlug).\(child.name.identifierSlug)")
    }

    private func delayValue(for child: ProxyGroupModel.Child) -> Text {
        if inflight.contains(child.name) {
            Text("a11y.proxyGroups.proxy.delay.testing")
        } else if let delay = child.delay, delay > 0 {
            Text("a11y.proxyGroups.proxy.delay \(String(delay))")
        } else {
            Text("a11y.proxyGroups.proxy.delay.none")
        }
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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let delay: Int?
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if let delay, delay > 0 {
                HStack(spacing: 2) {
                    if differentiateWithoutColor {
                        Image(systemName: symbol(for: delay))
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    Text("\(delay) ms")
                        .font(.caption.monospacedDigit())
                }
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
        case ..<200: AppTheme.connected
        case 200 ..< 500: AppTheme.warning
        default: AppTheme.danger
        }
    }

    private func symbol(for delay: Int) -> String {
        switch delay {
        case ..<200: "checkmark.circle.fill"
        case 200 ..< 500: "exclamationmark.circle"
        default: "exclamationmark.circle.fill"
        }
    }
}
