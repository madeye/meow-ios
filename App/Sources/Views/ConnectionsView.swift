import MeowModels
import SwiftUI

struct ConnectionsView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var connections: [Connection] = []
    @State private var query: String = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(filtered) { conn in
                row(for: conn)
            }
        }
        .listStyle(.plain)
        .overlay {
            if connections.isEmpty {
                ContentUnavailableView(
                    "connections.empty.title",
                    systemImage: "link",
                    description: Text("connections.empty.description"),
                )
                .accessibilityIdentifier("connections.emptyState")
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("connections.emptySearch")
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .searchable(text: $query)
        .navigationTitle(Text(
            "connections.nav.titleFormat \(connections.count)",
            comment: "Connections screen navigation title; %lld = current count",
        ))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("connections.toolbar.closeAll") {
                    Task { try? await api.closeAllConnections() }
                }
                .accessibilityIdentifier("connections.toolbar.closeAll")
            }
        }
        .task { await poll() }
    }

    private func row(for conn: Connection) -> some View {
        let slug = conn.id.identifierSlug
        return GlassCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(conn.metadata.host):\(conn.metadata.destinationPort)")
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityIdentifier("connections.row.\(slug).host")
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
                        .accessibilityIdentifier("connections.row.\(slug).chain")
                }
                Text("\(conn.rule) · \(conn.rulePayload)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connections.row.\(slug).rule")
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("connections.row.\(slug)")
        .swipeActions {
            Button(role: .destructive) {
                Task { try? await api.closeConnection(id: conn.id) }
            } label: {
                Label("connections.swipe.close", systemImage: "xmark")
            }
            .accessibilityIdentifier("connections.row.\(slug).close")
        }
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
        .accessibilityIdentifier("connections.errorBanner")
    }

    private var filtered: [Connection] {
        guard !query.isEmpty else { return connections }
        return connections.filter { $0.metadata.host.localizedCaseInsensitiveContains(query) }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let resp = try await api.getConnections()
                connections = resp.connections ?? []
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
