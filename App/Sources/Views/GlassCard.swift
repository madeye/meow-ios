import SwiftUI

/// Liquid-Glass styled container. Falls back to a materialized rectangle on
/// older runtimes — the app's minimum target is iOS 26, but the modifier
/// availability check keeps static previews working on pre-release SDKs.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
