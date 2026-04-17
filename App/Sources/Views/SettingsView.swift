import SwiftUI
import MeowModels

struct SettingsView: View {
    @State private var preferences: Preferences = Preferences.load(from: AppGroup.defaults)
    @State private var memoryMB: Int64?
    @Environment(MihomoAPI.self) private var api
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge

    var body: some View {
        Form {
            Section("General") {
                Toggle("Allow LAN", isOn: binding(\.allowLan))
                Toggle("IPv6", isOn: binding(\.ipv6))
                Picker("Log Level", selection: binding(\.logLevel)) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                    Text("Silent").tag("silent")
                }
            }
            Section("DNS") {
                TextField("DoH Server", text: binding(\.dohServer), prompt: Text("https://1.1.1.1/dns-query"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Memory", value: memoryMB.map { "\($0) MB" } ?? "—")
            }
            #if DEBUG
            Section("Debug Tunnel") {
                LabeledContent("Stage", value: String(describing: vpnManager.stage))
                LabeledContent("Ingress pkts", value: "\(ipcBridge.currentTraffic.ingressPackets)")
                LabeledContent("Egress pkts", value: "\(ipcBridge.currentTraffic.egressPackets)")
                Button("Install NE profile") { Task { await vpnManager.refresh() } }
                Button("Connect (no profile required)") { Task { await vpnManager.connect() } }
                Button("Disconnect", role: .destructive) { vpnManager.disconnect() }
            }
            #endif
        }
        .navigationTitle("Settings")
        .onChange(of: preferences.allowLan) { _, _ in persist() }
        .onChange(of: preferences.ipv6) { _, _ in persist() }
        .onChange(of: preferences.logLevel) { _, _ in persist() }
        .onChange(of: preferences.dohServer) { _, _ in persist() }
        .task { await refreshMemory() }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }

    private func persist() {
        preferences.save(to: AppGroup.defaults)
    }

    private func refreshMemory() async {
        if let mem = try? await api.getMemory() {
            memoryMB = mem.inuse / (1024 * 1024)
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
