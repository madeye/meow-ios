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
    @State private var inflightGroupTest: Set<String> = []
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
                            isTestingGroup: inflightGroupTest.contains(group.name),
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
                            onPingGroup: {
                                Task { await pingGroup(group) }
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
    static var screenshotDemoRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITests") && args.contains("-ScreenshotDemo")
    }

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
            // Screenshot harness: expand the first group so captures show
            // member proxies and delay badges, not just collapsed cards.
            if Self.screenshotDemoRequested, expandedGroupID == nil {
                expandedGroupID = groups.first?.id
            }
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

    static let delayTestURL = "http://www.gstatic.com/generate_204"

    func ping(proxy: String) async {
        inflightDelay.insert(proxy)
        _ = try? await meowAPI.testDelay(proxy: proxy, url: Self.delayTestURL)
        await refresh()
        inflightDelay.remove(proxy)
    }

    /// One-tap batch test for a whole group (issue #255). The engine
    /// probes every member and records the outcomes in each proxy's
    /// history, so a single `refresh()` afterwards repaints all badges.
    /// Failures are silent, matching the per-proxy `ping` — a 504 batch
    /// overrun still leaves partial results in the histories.
    func pingGroup(_ group: ProxyGroupModel) async {
        guard !inflightGroupTest.contains(group.name) else { return }
        inflightGroupTest.insert(group.name)
        let members = Set(group.children.map(\.name))
        inflightDelay.formUnion(members)
        _ = try? await meowAPI.testGroupDelay(group: group.name, url: Self.delayTestURL)
        await refresh()
        inflightGroupTest.remove(group.name)
        inflightDelay.subtract(members)
    }
}

private struct ProxyGroupCard: View {
    let group: ProxyGroupModel
    let isExpanded: Bool
    let inflight: Set<String>
    let isTestingGroup: Bool
    var onToggleExpand: () -> Void
    var onSelect: (String) -> Void
    var onPing: (String) -> Void
    var onPingGroup: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
                // Tap-gesture row (not a Button) so the group-test control
                // can live inside it with its own tap target — the same
                // idiom `proxyRow` uses for the delay badge.
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
                    groupTestControl
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(group.name)
                .accessibilityValue(isExpanded
                    ? Text("a11y.proxyGroups.group.expanded")
                    : Text("a11y.proxyGroups.group.collapsed"))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("a11y.proxyGroups.group.hint"))
                .accessibilityAction(named: Text("a11y.proxyGroups.group.action.testAll")) { onPingGroup() }

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

    /// Lightning-bolt tap target that fires the whole-group delay test;
    /// swaps to a spinner while the batch is in flight.
    private var groupTestControl: some View {
        Group {
            if isTestingGroup {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "bolt.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
        }
        .frame(minWidth: 32, minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { onPingGroup() }
    }

    private func proxyRow(_ child: ProxyGroupModel.Child) -> some View {
        HStack(spacing: 10) {
            Image(systemName: child.name == group.now ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(child.name == group.now ? AppTheme.accent : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name)
                    .font(.subheadline)
                    .lineLimit(1)
                // Provider-sourced stubs (issue #180) have an unknown
                // type — omit the caption instead of showing an empty row.
                if !child.type.isEmpty {
                    Text(child.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
