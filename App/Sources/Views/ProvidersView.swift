import MeowModels
import SwiftUI

struct ProvidersView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var providers: [Provider] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(providers, id: \.name) { provider in
                Section {
                    ForEach(provider.proxies ?? []) { proxy in
                        row(for: proxy, providerSlug: provider.name.identifierSlug)
                    }
                } header: {
                    sectionHeader(for: provider)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if providers.isEmpty {
                ContentUnavailableView(
                    "No providers",
                    systemImage: "tray",
                    description: Text("Providers appear when a profile is loaded."),
                )
                .accessibilityIdentifier("providers.emptyState")
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .navigationTitle("Providers (\(providers.count))")
        .task { await load() }
        .refreshable { await load() }
    }

    private func sectionHeader(for provider: Provider) -> some View {
        let slug = provider.name.identifierSlug
        return HStack {
            Text(provider.name)
                .accessibilityIdentifier("providers.section.\(slug).header")
            Spacer()
            Button {
                Task {
                    do {
                        try await api.healthCheckProvider(name: provider.name)
                        await load()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: "bolt.fill")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Health check \(provider.name)")
            .accessibilityIdentifier("providers.section.\(slug).healthCheck")
        }
    }

    private func row(for proxy: Proxy, providerSlug: String) -> some View {
        let proxySlug = proxy.name.identifierSlug
        return GlassCard {
            HStack {
                Text(proxy.name)
                    .lineLimit(1)
                    .accessibilityIdentifier("providers.row.\(providerSlug).\(proxySlug).name")
                Spacer()
                if let delay = proxy.history?.last?.delay {
                    Text("\(delay) ms")
                        .font(.caption.monospaced())
                        .foregroundStyle(delay > 500 ? .red : .green)
                        .accessibilityIdentifier("providers.row.\(providerSlug).\(proxySlug).delay")
                }
                Button {
                    Task {
                        do {
                            _ = try await api.testDelay(
                                proxy: proxy.name,
                                url: "http://www.gstatic.com/generate_204",
                            )
                            await load()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "bolt")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Test \(proxy.name)")
                .accessibilityIdentifier("providers.row.\(providerSlug).\(proxySlug).testButton")
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("providers.row.\(providerSlug).\(proxySlug)")
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
        .accessibilityIdentifier("providers.errorBanner")
    }

    private func load() async {
        do {
            let resp = try await api.getProviders()
            providers = Array(resp.providers.values).sorted { $0.name < $1.name }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
