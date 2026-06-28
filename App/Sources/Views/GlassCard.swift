import SwiftUI

private extension Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity,
        )
    }
}

enum AppTheme {
    static let canvas = Color(hex: 0xFBF3E4)
    static let panel = Color(hex: 0xFFFBF2)
    static let panelRaised = Color(hex: 0xF4E7CE)
    static let border = Color(hex: 0xD8C39B)
    static let accent = Color(hex: 0xE23E2C)
    static let connected = Color(hex: 0x156A5B)
    static let warning = Color(hex: 0xFF9E2C)
    static let danger = Color(hex: 0xE23E2C)
    static let mutedText = Color(hex: 0x6A574C)
    static let ink = Color(hex: 0x20140F)
    static let ginger = Color(hex: 0xED7E2B)

    static var screenBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                canvas,
                panel,
            ],
            startPoint: .top,
            endPoint: .bottom,
        )
    }

    static var iconBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                ginger.opacity(0.22),
                accent.opacity(0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing,
        )
    }
}

/// Container for major card surfaces, matching the meow-rs landing page paper
/// cards: warm paper, kraft border, and a restrained ink shadow.
/// Wrapper API is intentionally unchanged so the ~11 existing call sites
/// (Home, Traffic, Subscriptions, Providers, Rules, Connections) need no edits.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                AppTheme.panel,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1),
            )
            .shadow(color: AppTheme.ink.opacity(0.08), radius: 14, x: 0, y: 8)
    }
}
