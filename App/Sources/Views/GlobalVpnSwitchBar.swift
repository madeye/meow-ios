import MeowModels
import SwiftData
import SwiftUI

struct GlobalVpnSwitchBar: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    var body: some View {
        VStack(spacing: 0) {
            if let message = vpnManager.lastError {
                errorBanner(message)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            HStack(spacing: 12) {
                VpnStatusGlyph(stage: vpnManager.stage, size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stageBadgeText)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("vpn.status")
                    Text(profileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("vpn.profile.name")
                }

                Spacer(minLength: 8)

                Button(action: toggle) {
                    HStack(spacing: 6) {
                        if isInFlight {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .accessibilityHidden(true)
                        }
                        Image(systemName: isConnected ? "power.circle.fill" : "power.circle")
                            .imageScale(.medium)
                            .accessibilityHidden(true)
                        Text(toggleTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(minWidth: 116)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .tint(toggleTint)
                .disabled(toggleDisabled)
                .accessibilityIdentifier("vpn.toggle")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppTheme.panelRaised)
        .overlay(alignment: .bottom) {
            AppTheme.border.frame(height: 1)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("home.error.tunnelFailed.title")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button {
                vpnManager.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("home.error.dismiss")
            .accessibilityIdentifier("vpn.error.dismiss")
        }
        .padding(12)
        .background(AppTheme.panel, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1),
        )
        .accessibilityIdentifier("vpn.error.banner")
        .onAppear {
            AccessibilityNotification.Announcement(
                String(localized: "home.error.tunnelFailed.title"),
            ).post()
        }
    }

    private var profileName: String {
        selected.first?.name ?? String(
            localized: "home.profile.none",
            comment: "Placeholder shown in profile-name slot when no subscription profile is selected",
        )
    }

    private var isConnected: Bool {
        vpnManager.stage == .connected
    }

    private var isInFlight: Bool {
        let stage = vpnManager.stage
        return stage == .preparing || stage == .connecting || stage == .stopping
    }

    private var stageBadgeText: LocalizedStringKey {
        switch vpnManager.stage {
        case .idle, .stopped, .error: "home.badge.disconnected"
        case .preparing: "home.badge.preparing"
        case .connecting: "home.badge.connecting"
        case .connected: "home.badge.connected"
        case .stopping: "home.badge.disconnecting"
        }
    }

    private var toggleTitle: LocalizedStringKey {
        switch vpnManager.stage {
        case .connected: "home.toggle.disconnect"
        case .preparing: "home.toggle.preparing"
        case .connecting: "home.toggle.connecting"
        case .stopping: "home.toggle.disconnecting"
        default: "home.toggle.connect"
        }
    }

    private var toggleTint: Color {
        switch vpnManager.stage {
        case .connected: AppTheme.danger
        case .preparing, .connecting, .stopping: AppTheme.warning
        case .error: AppTheme.danger
        default: AppTheme.accent
        }
    }

    private var toggleDisabled: Bool {
        if isInFlight { return true }
        if isConnected { return false }
        return selected.first == nil
    }
}

private extension GlobalVpnSwitchBar {
    func toggle() {
        if isConnected {
            ipcBridge.send(.stop)
            Task { await vpnManager.disconnect() }
        } else {
            ipcBridge.send(.start, profileID: selected.first?.id)
            Task { await vpnManager.connect() }
        }
    }
}

struct VpnStatusGlyph: View {
    let stage: VpnStage
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            Image("AppMark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .overlay(alignment: .bottomTrailing) {
            StageDot(stage: stage, size: max(8, size * 0.19))
                .background(.background, in: Circle())
        }
        .accessibilityHidden(true)
    }
}

private struct StageDot: View {
    let stage: VpnStage
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 6)
    }

    private var color: Color {
        switch stage {
        case .idle, .stopped: .secondary
        case .preparing, .connecting, .stopping: AppTheme.warning
        case .connected: AppTheme.connected
        case .error: AppTheme.danger
        }
    }
}
