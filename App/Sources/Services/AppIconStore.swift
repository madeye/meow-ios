import Observation
import UIKit

/// The app's single observable copy of the Home Screen icon choice.
///
/// iOS keeps that choice in `UIApplication.alternateIconName`, a plain
/// property with no change notification. Settings used to own the value in
/// local `@State`, so nothing outside that screen could learn a switch had
/// happened — the status glyph on Home kept drawing the default artwork until
/// the next launch. Everything now reads `current` and writes through
/// `select(_:)`.
///
/// The system, not `Preferences`, is still the persistence layer: `current` is
/// seeded from `alternateIconName` at launch and only advances once iOS has
/// accepted a switch, so it never claims an icon that isn't installed.
@MainActor
@Observable
final class AppIconStore {
    /// The icon iOS has installed, as far as this process knows.
    private(set) var current: AppIcon

    /// `false` where the platform refuses icon switching — an iPad build
    /// running on macOS, for one. Callers hide the picker rather than let a
    /// tap fail. A fixed platform capability, so it is read on demand rather
    /// than cached at launch.
    var isSupported: Bool {
        system.supportsAlternateIcons
    }

    private let system: AlternateIconApplying

    init(system: AlternateIconApplying = SystemAlternateIcons()) {
        self.system = system
        current = AppIcon(alternateIconName: system.alternateIconName)
    }

    /// Switches the Home Screen icon. Returns `false` when iOS declined the
    /// change (Guided Access, a device-management profile) so the caller can
    /// explain why; `current` then re-syncs to whatever is really installed.
    func select(_ icon: AppIcon) async -> Bool {
        // Compared against the live value rather than `current`: after a
        // declined attempt `current` describes reality, and re-setting the
        // installed icon still pops the system's "you changed the icon" alert.
        guard icon.alternateIconName != system.alternateIconName else {
            current = icon
            return true
        }
        do {
            try await system.setAlternateIconName(icon.alternateIconName)
            current = icon
            return true
        } catch {
            current = AppIcon(alternateIconName: system.alternateIconName)
            return false
        }
    }
}

/// The slice of `UIApplication` the store needs, extracted so its
/// accept/decline handling is unit-testable — the real API mutates the
/// simulator's Home Screen and posts a system alert.
@MainActor
protocol AlternateIconApplying {
    var alternateIconName: String? { get }
    var supportsAlternateIcons: Bool { get }
    func setAlternateIconName(_ name: String?) async throws
}

/// Live implementation. Forwards to `UIApplication.shared` instead of
/// conforming `UIApplication` itself: `setAlternateIconName` is an
/// Objective-C completion-handler API that the compiler bridges to `async`,
/// and an explicit forwarder keeps that off the protocol witness table.
@MainActor
struct SystemAlternateIcons: AlternateIconApplying {
    var alternateIconName: String? {
        UIApplication.shared.alternateIconName
    }

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    func setAlternateIconName(_ name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}
