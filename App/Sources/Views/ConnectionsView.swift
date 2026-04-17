import SwiftUI

struct ConnectionsView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var connections: [Connection] = []
    @State private var query: String = ""

    var body: some View {
        List {
            ForEach(filtered) { conn in
                GlassCard {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(conn.metadata.host):\(conn.metadata.destinationPort)")
                                .font(.headline)
                                .lineLimit(1)
                            Spacer()
                            Text(conn.metadata.network.uppercased())
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: .capsule)
                        }
                        HStack(spacing: 10) {
                            let up = ByteCountFormatter.string(fromByteCount: conn.upload, countStyle: .binary)
                            let down = ByteCountFormatter.string(fromByteCount: conn.download, countStyle: .binary)
                            Label(up, systemImage: "arrow.up")
                            Label(down, systemImage: "arrow.down")
                            Spacer()
                            Text(conn.chains.reversed().joined(separator: " › "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("\(conn.rule) · \(conn.rulePayload)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { try? await api.closeConnection(id: conn.id) }
                    } label: { Label("Close", systemImage: "xmark") }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query)
        .navigationTitle("Connections (\(connections.count))")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Close All") { Task { try? await api.closeAllConnections() } }
            }
        }
        .task { await poll() }
    }

    private var filtered: [Connection] {
        guard !query.isEmpty else { return connections }
        return connections.filter { $0.metadata.host.localizedCaseInsensitiveContains(query) }
    }

    private func poll() async {
        while !Task.isCancelled {
            if let resp = try? await api.getConnections() {
                connections = resp.connections ?? []
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
