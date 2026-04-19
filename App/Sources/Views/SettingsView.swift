import MeowModels
import SwiftUI

struct SettingsView: View {
    @State private var preferences: Preferences = .load(from: AppGroup.defaults)
    @State private var memoryMB: Int64?
    #if DEBUG
        @State private var showDebugPanel = false
    #endif
    @Environment(MihomoAPI.self) private var api
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge

    var body: some View {
        Form {
            Section("settings.section.general") {
                Toggle("settings.toggle.allowLan", isOn: binding(\.allowLan))
                    .accessibilityIdentifier("settings.toggle.allowLan")
                Toggle("settings.toggle.ipv6", isOn: binding(\.ipv6))
                    .accessibilityIdentifier("settings.toggle.ipv6")
                Picker("settings.picker.logLevel", selection: binding(\.logLevel)) {
                    Text("settings.logLevel.debug").tag("debug")
                    Text("settings.logLevel.info").tag("info")
                    Text("settings.logLevel.warning").tag("warning")
                    Text("settings.logLevel.error").tag("error")
                    Text("settings.logLevel.silent").tag("silent")
                }
                .accessibilityIdentifier("settings.picker.logLevel")
            }
            Section("settings.section.dns") {
                TextField(
                    "settings.field.dohServer",
                    text: binding(\.dohServer),
                    prompt: Text("https://1.1.1.1/dns-query"),
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("settings.field.dohServer")
            }
            Section("settings.section.diagnostics") {
                NavigationLink {
                    UserDiagnosticsView()
                } label: {
                    Label("settings.label.diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.nav.diagnostics")
            }
            Section("settings.section.about") {
                LabeledContent("settings.about.version", value: appVersion)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("settings.about.version")
                #if DEBUG
                    .onTapGesture(count: 3) { showDebugPanel = true }
                #endif
                LabeledContent("settings.about.memory", value: memoryMB.map { "\($0) MB" } ?? "—")
                    .accessibilityIdentifier("settings.about.memory")
            }
            #if DEBUG
                Section("Debug Tunnel") {
                    LabeledContent("Stage", value: String(describing: vpnManager.stage))
                    LabeledContent("Ingress pkts", value: "\(ipcBridge.currentTraffic.ingressPackets)")
                    LabeledContent("Egress pkts", value: "\(ipcBridge.currentTraffic.egressPackets)")
                    Button("Install NE profile") { Task { await vpnManager.refresh() } }
                    Button("Connect (no profile required)") { Task { await vpnManager.connect() } }
                    Button("Disconnect", role: .destructive) { Task { await vpnManager.disconnect() } }
                    NavigationLink("Open Diagnostics") {
                        DiagnosticsPanelView()
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            #endif
        }
        .navigationTitle("settings.nav.title")
        #if DEBUG
            .navigationDestination(isPresented: $showDebugPanel) {
                DiagnosticsPanelView()
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("settings.debug.diagnosticsPanel")
            }
        #endif
            .onChange(of: preferences.allowLan) { _, _ in persist() }
            .onChange(of: preferences.ipv6) { _, _ in persist() }
            .onChange(of: preferences.logLevel) { _, _ in persist() }
            .onChange(of: preferences.dohServer) { _, _ in persist() }
            .task { await pollMemory() }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 },
        )
    }

    private func persist() {
        preferences.save(to: AppGroup.defaults)
    }

    private func pollMemory() async {
        while !Task.isCancelled {
            await refreshMemory()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func refreshMemory() async {
        if let mem = try? await api.getMemory() {
            memoryMB = mem.inuse / (1024 * 1024)
        } else {
            memoryMB = nil
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
