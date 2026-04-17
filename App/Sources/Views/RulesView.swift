import SwiftUI

struct RulesView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var rules: [Rule] = []
    @State private var error: String?

    var body: some View {
        List(rules) { rule in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.type)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: .capsule)
                    Text(rule.payload).lineLimit(1)
                    Spacer()
                    Text(rule.proxy).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Rules")
        .refreshable { await load() }
        .task { await load() }
        .overlay(alignment: .center) {
            if let error { Text(error).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        do {
            rules = try await api.getRules().rules
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
