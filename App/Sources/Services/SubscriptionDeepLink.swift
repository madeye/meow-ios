import Foundation

/// Parsed `meow://connect?url=<encoded>[&name=<encoded>][&select=1]`
/// subscription-import deep link. Pure parsing — the actual
/// fetch/persist happens through `SubscriptionService.add(name:url:)`
/// so the existing auth, timeout, YAML validation, and persistence
/// code path is reused unchanged.
///
/// Routing lives in `ContentView.onOpenURL`; this type is separate so
/// URL semantics can be unit-tested without UIKit.
struct SubscriptionDeepLink: Equatable, Sendable {
    let subscriptionURL: URL
    let name: String
    let autoSelect: Bool

    /// Returns `nil` for anything that isn't a well-formed
    /// `meow://connect?url=…` link — unknown hosts (`meow://foo`),
    /// missing `url=`, or `url=` values that don't parse as http/https
    /// are all rejected here so `ContentView` doesn't have to branch.
    ///
    /// **Security**: we only accept `http`/`https` subscription URLs.
    /// `file://`, `data:` etc. would let a crafted link read arbitrary
    /// local paths or inject inline YAML, so they're rejected outright.
    static func parse(_ deepLink: URL) -> SubscriptionDeepLink? {
        guard deepLink.scheme == "meow", deepLink.host == "connect" else {
            return nil
        }
        guard let components = URLComponents(url: deepLink, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }

        guard let rawURL = items.first(where: { $0.name == "url" })?.value,
              let subscriptionURL = URL(string: rawURL),
              let scheme = subscriptionURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              subscriptionURL.host?.isEmpty == false else {
            return nil
        }

        let explicit = items.first(where: { $0.name == "name" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let explicit, !explicit.isEmpty {
            name = explicit
        } else {
            name = subscriptionURL.host ?? "Subscription"
        }

        let autoSelect = items.first(where: { $0.name == "select" })?.value == "1"

        return SubscriptionDeepLink(
            subscriptionURL: subscriptionURL,
            name: name,
            autoSelect: autoSelect
        )
    }
}
