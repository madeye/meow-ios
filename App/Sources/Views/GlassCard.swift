import SwiftUI

/// Liquid Glass container for major card surfaces. Routes the background
/// through iOS 26's native `.glassEffect(in:)` modifier (PRD §4.1) so each
/// instance picks up system vibrancy, adaptive contrast, and light/dark
/// tuning without the hand-rolled `.regularMaterial` + stroke overlay the
/// pre-T5.1 implementation used. Wrapper API is intentionally unchanged
/// from the pre-T5.1 version so the ~11 existing call sites (Home, Traffic,
/// Subscriptions, Providers, Rules, Connections) need no edits.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}
