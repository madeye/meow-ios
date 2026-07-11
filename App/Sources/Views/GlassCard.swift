import SwiftUI

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1,
        )
    }
}

private extension Color {
    /// Dynamic brand color: resolves per trait collection so every AppTheme
    /// token adapts when the system switches between light and dark.
    init(light: Int, dark: Int) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

enum AppTheme {
    // Brand colors sampled from the established leaping-cat app icon; each
    // token carries a dark-appearance variant on the same hue.
    static let canvas = Color(light: 0xEAF8FF, dark: 0x0B1720)
    static let panel = Color(light: 0xFFFFFF, dark: 0x152430)
    static let panelRaised = Color(light: 0xDDF3FF, dark: 0x1C3040)
    static let border = Color(light: 0xA8D8F0, dark: 0x2C4A60)
    static let accent = Color(light: 0x0077CC, dark: 0x2CB5FF)
    static let navy = Color(light: 0x0049B8, dark: 0x000000)
    static let ginger = Color(light: 0xFE9B01, dark: 0xFFB340)

    // Semantic colors remain distinct from the brand palette.
    static let connected = Color(light: 0x148742, dark: 0x33C377)
    static let warning = Color(light: 0xF29A00, dark: 0xFFB84D)
    static let danger = Color(light: 0xD9363E, dark: 0xFF6B70)
    static let mutedText = Color(light: 0x526B7A, dark: 0x9DB6C6)
    static let ink = Color(light: 0x102A43, dark: 0xE8F2FA)

    static var screenBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                canvas,
                Color(light: 0xF7FCFF, dark: 0x0E1C2A),
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
