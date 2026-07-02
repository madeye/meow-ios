import MeowModels
import SwiftUI

struct DnsView: View {
    @Environment(MeowAPI.self) private var api
    @State private var results: [DnsResult] = []
    @State private var query: String = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(results) { result in
                row(for: result)
            }
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView(
                        "dns.empty.title",
                        systemImage: "network",
                        description: Text("dns.empty.description"),
                    )
                    .accessibilityIdentifier("dns.emptyState")
                } else {
                    ContentUnavailableView.search(text: query)
                        .accessibilityIdentifier("dns.emptySearch")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    accessibilityLabel: Text("a11y.dns.errorBanner \(errorMessage)"),
                    identifier: "dns.errorBanner",
                )
            }
        }
        .searchable(text: $query)
        .navigationTitle(Text(
            "dns.nav.titleFormat \(displayCount)",
            comment: "DNS screen navigation title; %lld = result count",
        ))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) { await poll() }
    }

    private var displayCount: Int {
        results.count
    }

    private func row(for result: DnsResult) -> some View {
        let slug = result.name.identifierSlug
        let ips = result.ips.joined(separator: ", ")
        let upstream = result.fromServer ?? String(localized: "dns.row.unknownUpstream")
        let ttl = Int(result.ttl)
        return GlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityIdentifier("dns.row.\(slug).domain")
                Text(ips)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .accessibilityIdentifier("dns.row.\(slug).ips")
                HStack(spacing: 10) {
                    Label(upstream, systemImage: "server.rack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("dns.row.\(slug).upstream")
                    Spacer()
                    Text("dns.row.ttl \(ttl)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dns.row.\(slug).ttl")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("a11y.dns.row.label \(result.name) \(ips) \(upstream) \(ttl)"))
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("dns.row.\(slug)")
    }

    private func poll() async {
        let search = query.isEmpty ? nil : query
        while !Task.isCancelled {
            do {
                let fetched = try await api.getDnsResults(search: search)
                results = fetched
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
