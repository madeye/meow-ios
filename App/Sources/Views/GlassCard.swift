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
    // Brand colors sampled from the established leaping-cat app icon.
    static let canvas = Color(hex: 0xEAF8FF)
    static let panel = Color(hex: 0xFFFFFF)
    static let panelRaised = Color(hex: 0xDDF3FF)
    static let border = Color(hex: 0xA8D8F0)
    static let accent = Color(hex: 0x0077CC)
    static let navy = Color(hex: 0x0049B8)
    static let ginger = Color(hex: 0xFE9B01)

    // Semantic colors remain distinct from the brand palette.
    static let connected = Color(hex: 0x148742)
    static let warning = Color(hex: 0xF29A00)
    static let danger = Color(hex: 0xD9363E)
    static let mutedText = Color(hex: 0x526B7A)
    static let ink = Color(hex: 0x102A43)

    static var screenBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                canvas,
                Color(hex: 0xF7FCFF),
            ],
            startPoint: .top,
            endPoint: .bottom,
        )
    }

    static var iconBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                ginger.opacity(0.18),
                accent.opacity(0.12),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing,
        )
    }
}

/// Container for major card surfaces, using the app icon's white, cyan, and
/// scarf-navy visual language without competing with the content.
/// Wrapper API is intentionally unchanged so the ~11 existing call sites
/// (Home, Traffic, Subscriptions, Providers, Rules, Connections) need no edits.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                AppTheme.panel,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1),
            )
            .shadow(color: AppTheme.navy.opacity(0.10), radius: 16, x: 0, y: 8)
    }
}
