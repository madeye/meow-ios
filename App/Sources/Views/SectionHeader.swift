import SwiftUI

/// Shared section-header treatment so every tab renders the same small-caps
/// header (Subscriptions rolled its own; Settings used the Form default,
/// which draws larger sentence-case titles).
struct SectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.mutedText)
            .textCase(.uppercase)
    }
}
