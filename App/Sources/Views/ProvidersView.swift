import SwiftUI

struct ProvidersView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var providers: [Provider] = []

    var body: some View {
        List {
            ForEach(providers, id: \.name) { provider in
                Section(provider.name) {
                    ForEach(provider.proxies ?? []) { proxy in
                        HStack {
                            Text(proxy.name)
                            Spacer()
                            if let delay = proxy.history?.last?.delay {
                                Text("\(delay) ms")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(delay > 500 ? .red : .green)
                            }
                            Button {
                                Task {
                                    _ = try? await api.testDelay(
                                        proxy: proxy.name,
                                        url: "http://www.gstatic.com/generate_204",
                                    )
                                    await load()
                                }
                            } label: {
                                Image(systemName: "bolt")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Providers")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let resp = try? await api.getProviders() {
            providers = Array(resp.providers.values).sorted { $0.name < $1.name }
        }
    }
}
