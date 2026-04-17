import SwiftUI
import SwiftData
import MeowModels

struct HomeView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(MihomoAPI.self) private var mihomoAPI
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            StageDot(stage: vpnManager.stage)
                            Text(stageLabel)
                                .font(.headline)
                            Spacer()
                            if let profile = selected.first {
                                Text(profile.name)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Button(action: toggle) {
                            Text(isConnected ? "Disconnect" : "Connect")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(selected.first == nil)
                    }
                }

                HStack(spacing: 12) {
                    TrafficTile(title: "Upload", bytes: ipcBridge.currentTraffic.uploadBytes, rate: ipcBridge.currentTraffic.uploadRate, systemImage: "arrow.up")
                    TrafficTile(title: "Download", bytes: ipcBridge.currentTraffic.downloadBytes, rate: ipcBridge.currentTraffic.downloadRate, systemImage: "arrow.down")
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proxy Groups")
                            .font(.caption.smallCaps())
                            .foregroundStyle(.secondary)
                        Text("Connect to populate available groups.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("meow")
    }

    private var isConnected: Bool { vpnManager.stage == .connected || vpnManager.stage == .connecting }

    private var stageLabel: String {
        switch vpnManager.stage {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .stopping: return "Stopping…"
        case .stopped: return "Disconnected"
        case .error: return vpnManager.lastError ?? "Error"
        }
    }

    private func toggle() {
        if isConnected {
            ipcBridge.send(.stop)
            vpnManager.disconnect()
        } else {
            ipcBridge.send(.start, profileID: selected.first?.id)
            Task { await vpnManager.connect() }
        }
    }
}

private struct StageDot: View {
    let stage: VpnStage
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.6), radius: 6)
    }
    private var color: Color {
        switch stage {
        case .idle, .stopped: return .secondary
        case .connecting, .stopping: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
}

private struct TrafficTile: View {
    let title: String
    let bytes: Int64
    let rate: Int64
    let systemImage: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: rate, countStyle: .binary) + "/s")
                    .font(.title3.bold())
                Text("Total " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
