import Foundation

/// How often a profile re-fetches its subscription URL without the user
/// asking. Persisted per profile as a raw string (`Profile.updateIntervalRaw`)
/// and evaluated by `ProfileAutoUpdater`.
enum ProfileUpdateInterval: String, CaseIterable, Identifiable {
    /// Never refetches on its own — updates come from the user (either row
    /// swipe direction, or a YAML edit).
    case manual
    case daily
    case weekly

    /// What a profile gets when no cadence has been chosen for it. Profiles
    /// created before this setting existed therefore keep exactly their
    /// pre-feature behaviour: no fetch happens until the user opts in.
    static let fallback: ProfileUpdateInterval = .manual

    var id: String {
        rawValue
    }

    /// How stale `Profile.lastUpdated` has to be before an automatic refresh
    /// is due. `nil` means "never due".
    var refreshAfter: TimeInterval? {
        switch self {
        case .manual: nil
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }

    /// Localizable.strings key for the picker option and the row badge.
    var titleKey: String {
        switch self {
        case .manual: "subscriptions.updateInterval.manual"
        case .daily: "subscriptions.updateInterval.daily"
        case .weekly: "subscriptions.updateInterval.weekly"
        }
    }

    /// Decodes the persisted raw value. An unrecognised string — written by a
    /// newer build whose store was then opened by an older one — degrades to
    /// `fallback` instead of trapping on a failable initializer.
    init(storedRawValue: String) {
        self = ProfileUpdateInterval(rawValue: storedRawValue) ?? .fallback
    }
}
