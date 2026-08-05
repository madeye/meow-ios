import Foundation

/// Decision data for the in-app confirmation shown before a `meow://connect`
/// deep link is allowed to fetch or activate anything (issue #293 — a
/// crafted link must never import, let alone activate, a proxy profile
/// unattended).
///
/// Built once per incoming deep link via `make(for:existingProfiles:)`, a
/// pure function with no networking or persistence, so the decision logic
/// (host / name / HTTPS / duplicate detection) is unit-testable without
/// SwiftUI or a live `ModelContext`. `ContentView` presents this as a sheet
/// and reduces the user's choice through `DeepLinkImportCoordinator`.
struct DeepLinkImportConfirmation: Identifiable, Equatable {
    let id = UUID()
    let link: SubscriptionDeepLink
    /// Set when a profile already exists with this exact subscription URL —
    /// the confirmation offers "update in place" instead of a duplicate add,
    /// so a replayed/duplicate deep link can't silently accumulate profiles.
    let existingProfileID: UUID?

    var subscriptionURL: URL {
        link.subscriptionURL
    }

    var host: String {
        link.subscriptionURL.host ?? link.subscriptionURL.absoluteString
    }

    var name: String {
        link.name
    }

    /// Plain-HTTP links reach the confirmation sheet (so the user learns
    /// why they won't work) but the actual import is rejected by
    /// `SubscriptionService.rejectPlainHTTP` — ATS blocks cleartext HTTP,
    /// so the fetch could never succeed anyway.
    var isInsecure: Bool {
        link.subscriptionURL.scheme?.lowercased() == "http"
    }

    var isDuplicate: Bool {
        existingProfileID != nil
    }

    /// The deep link asked for `select=1`. This only controls whether the
    /// confirmation *offers* a separate "Import & Activate" action — the
    /// query parameter never activates anything by itself; only an explicit
    /// tap on that action does.
    var requestsActivation: Bool {
        link.autoSelect
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.link == rhs.link && lhs.existingProfileID == rhs.existingProfileID
    }

    /// - Parameter existingProfiles: `(id, url)` pairs for every profile
    ///   already imported, used only to detect a replayed subscription URL.
    ///   Kept as plain tuples (rather than taking `[Profile]` / a
    ///   `ModelContext` directly) so this stays a pure function callable
    ///   from unit tests with no SwiftData store.
    static func make(
        for link: SubscriptionDeepLink,
        existingProfiles: [(id: UUID, url: String)],
    ) -> Self {
        let existingProfileID = existingProfiles.first { $0.url == link.subscriptionURL.absoluteString }?.id
        return DeepLinkImportConfirmation(link: link, existingProfileID: existingProfileID)
    }
}

/// Action chosen from the deep-link confirmation sheet.
enum DeepLinkConfirmationAction: Equatable {
    case cancel
    case importOnly
    case importAndActivate
}

/// Executes the user's choice from the confirmation sheet against
/// `SubscriptionService`. Kept separate from the view so the import /
/// activate / no-op behavior is unit-testable without UIKit or SwiftUI.
@MainActor
struct DeepLinkImportCoordinator {
    let subscriptionService: SubscriptionService

    /// - Parameter existingProfile: the profile matching
    ///   `confirmation.existingProfileID`, looked up by the caller (e.g. from
    ///   a `@Query` result) since this type has no `ModelContext` of its own.
    /// - Returns: the imported/updated profile, or `nil` for `.cancel` (no
    ///   fetch, import, or activation happens in that case).
    @discardableResult
    func resolve(
        _ confirmation: DeepLinkImportConfirmation,
        action: DeepLinkConfirmationAction,
        existingProfile: Profile?,
    ) async throws -> Profile? {
        guard action != .cancel else { return nil }

        let profile: Profile = if let existingProfile {
            try await refreshed(existingProfile)
        } else {
            try await subscriptionService.add(
                name: confirmation.name,
                url: confirmation.subscriptionURL.absoluteString,
            )
        }

        // Defense in depth: only an explicit `.importAndActivate` tap on a
        // confirmation that actually offered it may select the profile.
        // `select=1` alone (requestsActivation) never reaches this path.
        if action == .importAndActivate, confirmation.requestsActivation {
            try subscriptionService.select(profile)
        }
        return profile
    }

    private func refreshed(_ profile: Profile) async throws -> Profile {
        try await subscriptionService.refresh(profile)
        return profile
    }
}
