import SwiftUI

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
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5),
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}
