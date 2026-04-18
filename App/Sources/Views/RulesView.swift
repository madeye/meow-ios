import MeowModels
import SwiftUI

struct RulesView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var rules: [Rule] = []
    @State private var errorMessage: String?

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
        .accessibilityIdentifier("rules.row.\(index)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal)
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
