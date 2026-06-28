import MeowModels
import SwiftUI

struct ProvidersView: View {
    @Environment(MeowAPI.self) private var api
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
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
                    "providers.empty.title",
                    systemImage: "tray",
                    description: Text("providers.empty.description"),
                )
                .accessibilityIdentifier("providers.emptyState")
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .navigationTitle(Text(
            "providers.nav.titleFormat \(providers.count)",
            comment: "Providers screen navigation title; %lld = provider count",
        ))
        .task { await load() }
        .refreshable { await load() }
    }

    private func sectionHeader(for provider: Provider) -> some View {
        let slug = provider.name.identifierSlug
        return HStack {
            Text(provider.name)
                .accessibilityAddTraits(.isHeader)
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
            .accessibilityLabel(Text(
                "providers.a11y.healthCheck \(provider.name)",
                comment: "Providers section health-check button a11y label; %@ = provider name",
            ))
            .accessibilityIdentifier("providers.section.\(slug).healthCheck")
        }
    }

    private func delayBadge(delay: Int, providerSlug: String, proxySlug: String) -> some View {
        HStack(spacing: 2) {
            if differentiateWithoutColor {
                Image(systemName: delay > 500 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text("\(delay) ms")
                .font(.caption.monospaced())
                .foregroundStyle(delay > 500 ? AppTheme.danger : AppTheme.connected)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.providers.row.delay.label"))
        .accessibilityValue(Text("a11y.providers.row.delay.value \(delay)"))
        .accessibilityIdentifier("providers.row.\(providerSlug).\(proxySlug).delay")
    }

    private func row(for proxy: Proxy, providerSlug: String) -> some View {
        let proxySlug = proxy.name.identifierSlug
        return GlassCard {
            HStack {
                VStack(alignment: .leading) {
                    Text(proxy.name)
                        .lineLimit(1)
                        .accessibilityIdentifier("providers.row.\(providerSlug).\(proxySlug).name")
                    if let delay = proxy.history?.last?.delay {
                        delayBadge(delay: delay, providerSlug: providerSlug, proxySlug: proxySlug)
                    }
                }
                Spacer()
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
                .accessibilityLabel(Text(
                    "providers.a11y.test \(proxy.name)",
                    comment: "Providers row test-delay button a11y label; %@ = proxy name",
                ))
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
        .accessibilityLabel(Text("a11y.providers.errorBanner.label \(message)"))
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
