import MeowIPC
import MeowModels
import NetworkExtension
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var preferences: Preferences = .load(from: AppGroup.defaults)
    @State private var memoryMB: Int64?
    @State private var logExportDocument: LogExportDocument?
    @State private var showingLogExporter = false
    @State private var exportingLogs = false
    #if DEBUG
        @State private var showDebugPanel = false
    #endif
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge

    var body: some View {
        Form {
            Section("settings.section.general") {
                Toggle("settings.toggle.allowLan", isOn: binding(\.allowLan))
                    .accessibilityIdentifier("settings.toggle.allowLan")
                    .accessibilityHint(Text("a11y.settings.allowLan.hint"))
                Toggle("settings.toggle.onDemand", isOn: binding(\.onDemand))
                    .accessibilityIdentifier("settings.toggle.onDemand")
                    .accessibilityHint(Text("a11y.settings.onDemand.hint"))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("settings.toggle.blockHTTP3", isOn: binding(\.blockHTTP3))
                        .accessibilityIdentifier("settings.toggle.blockHTTP3")
                        .accessibilityHint(Text("a11y.settings.blockHTTP3.hint"))
                    Text("settings.toggle.blockHTTP3.footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("settings.toggle.ipv6", isOn: binding(\.ipv6Enabled))
                        .accessibilityIdentifier("settings.toggle.ipv6")
                        .accessibilityHint(Text("a11y.settings.ipv6.hint"))
                    Text("settings.toggle.ipv6.footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Picker("settings.picker.logLevel", selection: binding(\.logLevel)) {
                    Text("settings.logLevel.debug").tag("debug")
                    Text("settings.logLevel.info").tag("info")
                    Text("settings.logLevel.warning").tag("warning")
                    Text("settings.logLevel.error").tag("error")
                    Text("settings.logLevel.silent").tag("silent")
                }
                .accessibilityIdentifier("settings.picker.logLevel")
            }
            Section("settings.section.diagnostics") {
                NavigationLink {
                    UserDiagnosticsView()
                } label: {
                    Label("settings.label.diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.nav.diagnostics")
                Button {
                    Task { await exportLogs() }
                } label: {
                    HStack {
                        Label("settings.label.exportLogs", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exportingLogs {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                    }
                }
                .disabled(exportingLogs)
                .accessibilityIdentifier("settings.button.exportLogs")
                .accessibilityValue(exportingLogs ? String(localized: "a11y.settings.exportLogs.inProgress") : "")
                .accessibilityHint(Text("a11y.settings.exportLogs.hint"))
            }
            Section("settings.section.about") {
                LabeledContent("settings.about.version", value: appVersion)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("settings.about.version")
                #if DEBUG
                    .onTapGesture(count: 3) { showDebugPanel = true }
                    // The triple-tap easter egg is unreachable for VoiceOver
                    // and Switch Control users; expose it as a named action.
                    .accessibilityAction(named: Text(verbatim: "Open debug panel")) { showDebugPanel = true }
                #endif
                LabeledContent("settings.about.memory", value: memoryText ?? "—")
                    .accessibilityIdentifier("settings.about.memory")
                    .accessibilityValue(memoryText ?? String(localized: "a11y.settings.memory.unavailable"))
                    .accessibilityAddTraits(.updatesFrequently)
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
        .scrollContentBackground(.hidden)
        .background(AppTheme.screenBackground)
        .navigationTitle("settings.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
            .navigationDestination(isPresented: $showDebugPanel) {
                DiagnosticsPanelView()
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("settings.debug.diagnosticsPanel")
            }
        #endif
            .onChange(of: preferences.allowLan) { _, _ in persist() }
            .onChange(of: preferences.blockHTTP3) { _, _ in persist() }
            .onChange(of: preferences.ipv6Enabled) { _, _ in persist() }
            .onChange(of: preferences.logLevel) { _, _ in persist() }
            .onChange(of: preferences.onDemand) { _, _ in
                persist()
                // Push the new isOnDemandEnabled value into the live NE
                // profile; otherwise the toggle only takes effect on next
                // app launch.
                Task { await vpnManager.refresh() }
            }
            .task { await pollMemory() }
            .fileExporter(
                isPresented: $showingLogExporter,
                document: logExportDocument,
                contentType: .plainText,
                defaultFilename: "meow-tunnel-\(logTimestamp).log",
            ) { _ in
                logExportDocument = nil
            }
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

    /// Asks the PacketTunnel extension for its current physical memory
    /// footprint via the `DiagnosticsIPC` `0x03` channel. meow's `/memory`
    /// REST endpoint is WebSocket-only in meow-rs, so the previous
    /// `api.getMemory()` path always 400'd. This IPC reads
    /// `task_info(TASK_VM_INFO).phys_footprint` inside the extension — the
    /// same metric iOS jetsam compares against the NE memory limit and that
    /// Xcode's Memory gauge shows. Returns `nil` when the tunnel isn't running.
    private func refreshMemory() async {
        guard vpnManager.stage == .connected else {
            memoryMB = nil
            return
        }
        let managers = await (try? NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let session = managers.first?.connection as? NETunnelProviderSession else {
            memoryMB = nil
            return
        }
        let bytes = await withCheckedContinuation { (cont: CheckedContinuation<UInt64?, Never>) in
            do {
                try session.sendProviderMessage(DiagnosticsIPC.encodeMemoryRequest()) { data in
                    guard let data,
                          let response = try? DiagnosticsIPC.decodeMemoryResponse(data)
                    else {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(returning: response.residentBytes)
                }
            } catch {
                cont.resume(returning: nil)
            }
        }
        memoryMB = bytes.map { Int64($0 / (1024 * 1024)) }
    }

    private var memoryText: String? {
        memoryMB.map { "\($0) MB" }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    private var logTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private func exportLogs() async {
        exportingLogs = true
        defer { exportingLogs = false }
        let text = await Task.detached { collectCombinedLogs() }.value
        logExportDocument = LogExportDocument(text: text)
        showingLogExporter = true
    }
}

/// Combine the app's own unified-log entries with the packet-tunnel + engine
/// file log. The two live in different processes: the app can only read its own
/// PID via `OSLogStore`, so the tunnel's output is captured to a shared App
/// Group file by the engine (`file_log.rs`) and the NE host (`MWEngineLog`).
private func collectCombinedLogs() -> String {
    """
    ===== App process — OSLog, last hour =====
    \(collectOSLogs())

    ===== Packet Tunnel + engine — \(AppGroup.tunnelLogURL.lastPathComponent) =====
    \(collectTunnelFileLog())
    """
}

/// Read the App Group tunnel log ring (rotated file first, then the active
/// file) and return its tail, capped so the export stays manageable. Reads on a
/// background queue; failures degrade to an explanatory line rather than
/// throwing.
private func collectTunnelFileLog() -> String {
    // Cap the exported tail. The on-disk ring is larger (file_log.rs), but the
    // most recent window is what matters for a freeze post-mortem.
    let maxBytes = 512 * 1024
    var data = Data()
    if let rotated = try? Data(contentsOf: AppGroup.tunnelLogURL.appendingPathExtension("1")) {
        data.append(rotated)
    }
    if let active = try? Data(contentsOf: AppGroup.tunnelLogURL) {
        data.append(active)
    }
    if data.isEmpty {
        return """
        No packet-tunnel log file at \(AppGroup.tunnelLogURL.path).
        Connect the tunnel at least once — the engine writes this file while running.
        """
    }
    if data.count > maxBytes {
        data = data.suffix(maxBytes)
    }
    // Lossy decode is deliberate: the byte-cap suffix can slice mid-UTF8, and
    // the failable `String(bytes:encoding:)` would return nil — dropping the
    // entire tail — whereas this preserves it, substituting U+FFFD for the one
    // truncated codepoint at the boundary.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: data, as: UTF8.self)
}

private func collectOSLogs() -> String {
    var lines: [String] = []
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    do {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date().addingTimeInterval(-3600))
        let entries = try store.getEntries(at: since)
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            let ts = df.string(from: log.date)
            let lvl = switch log.level {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .notice: "NOTICE"
            case .error: "ERROR"
            case .fault: "FAULT"
            default: "LOG"
            }
            lines.append("[\(ts)] [\(lvl)] [\(log.subsystem)/\(log.category)] \(log.composedMessage)")
        }
    } catch {
        lines.append("Failed to read OSLogStore: \(error.localizedDescription)")
    }
    if lines.isEmpty {
        lines.append("No log entries found in the last hour.")
    }
    return lines.joined(separator: "\n")
}

struct LogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText]
    }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
