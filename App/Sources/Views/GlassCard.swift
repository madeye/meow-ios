import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.10, green: 0.43, blue: 0.86)
    static let connected = Color(red: 0.18, green: 0.64, blue: 0.38)
    static let warning = Color(red: 0.86, green: 0.52, blue: 0.18)
    static let danger = Color(red: 0.86, green: 0.24, blue: 0.24)

    static var screenBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                Color(uiColor: .secondarySystemBackground).opacity(0.72),
            ],
            startPoint: .top,
            endPoint: .bottom,
        )
    }

    static var iconBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                accent.opacity(0.18),
                accent.opacity(0.07),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing,
        )
    }
}

/// Material container for major card surfaces. Uses `.regularMaterial` plus
/// a thin stroke overlay so the wrapper renders consistently from iOS 17 up.
/// Wrapper API is intentionally unchanged so the ~11 existing call sites
/// (Home, Traffic, Subscriptions, Providers, Rules, Connections) need no edits.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5),
            )
            .shadow(color: .black.opacity(0.045), radius: 8, y: 2)
    }
}
