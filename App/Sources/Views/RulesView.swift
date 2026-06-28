import MeowModels
import SwiftData
import SwiftUI

struct RulesView: View {
    @Environment(MeowAPI.self) private var api
    /// The user's active profile drives the editor — that's where the
    /// authoritative `rules:` block lives. The Edit button stays disabled
    /// while no profile is selected (matches `ProxyGroupsView`'s pattern).
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]
    @State private var rules: [Rule] = []
    @State private var errorMessage: String?
    @State private var presentingEditor = false

    var body: some View {
        List {
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                row(for: rule, index: index)
            }
        }
        .listStyle(.plain)
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView(
                    "rules.empty.title",
                    systemImage: "arrow.triangle.branch",
                    description: Text("rules.empty.description"),
                )
                .accessibilityIdentifier("rules.emptyState")
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .navigationTitle(Text(
            "rules.nav.titleFormat \(rules.count)",
            comment: "Rules screen navigation title; %lld = rule count",
        ))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentingEditor = true
                } label: {
                    Label("rules.button.edit", systemImage: "pencil")
                }
                .disabled(selected.first == nil)
                .accessibilityIdentifier("rules.editButton")
            }
        }
        .sheet(
            isPresented: $presentingEditor,
            // The editor wrote the source YAML; the live `/rules` table is
            // still serving pre-edit state until the tunnel restarts. Re-
            // fetch anyway so any same-process edits that the engine *does*
            // pick up (none today, but cheap insurance) become visible.
            onDismiss: { Task { await load() } },
            content: {
                if let profile = selected.first {
                    RulesEditorView(profile: profile)
                }
            },
        )
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(for rule: Rule, index: Int) -> some View {
        GlassCard {
            HStack(spacing: 8) {
                Text(rule.type)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: .capsule)
                    .accessibilityIdentifier("rules.row.\(index).type")
                Text(rule.payload)
                    .lineLimit(1)
                    .accessibilityIdentifier("rules.row.\(index).payload")
                Spacer()
                Text(rule.proxy)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("rules.row.\(index).proxy")
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.rules.row \(rule.type) \(rule.payload) \(rule.proxy)"))
        .accessibilityIdentifier("rules.row.\(index)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.rules.error \(message)"))
        .accessibilityIdentifier("rules.errorBanner")
    }

    private func load() async {
        do {
            rules = try await api.getRules().rules
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
