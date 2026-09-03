import Foundation
@testable import meow_ios
import Testing

@MainActor
@Suite("AppIconStore")
struct AppIconStoreTests {
    @Test
    func `seeds the current icon from what iOS has installed`() {
        let system = StubAlternateIcons(installed: AppIcon.sunset.alternateIconName)
        #expect(AppIconStore(system: system).current == .sunset)
    }

    @Test
    func `seeds primary when no alternate icon is installed`() {
        #expect(AppIconStore(system: StubAlternateIcons(installed: nil)).current == .primary)
    }

    @Test
    func `an icon dropped in an app update seeds as primary`() {
        let system = StubAlternateIcons(installed: "AppIconRemovedLastRelease")
        #expect(AppIconStore(system: system).current == .primary)
    }

    @Test
    func `select publishes the new icon once iOS accepts it`() async {
        let system = StubAlternateIcons(installed: nil)
        let store = AppIconStore(system: system)

        #expect(await store.select(.midnight))

        #expect(store.current == .midnight)
        #expect(system.alternateIconName == "AppIconMidnight")
    }

    @Test
    func `a declined switch keeps the installed icon and reports failure`() async {
        // Guided Access and management profiles both make setAlternateIconName
        // throw; the picker turns the `false` into its error banner.
        let system = StubAlternateIcons(installed: AppIcon.leap.alternateIconName)
        system.failure = IconChangeDeclined()
        let store = AppIconStore(system: system)

        #expect(await store.select(.sunset) == false)

        #expect(store.current == .leap)
        #expect(system.alternateIconName == "AppIconLeap")
    }

    @Test
    func `selecting the installed icon leaves UIKit alone`() async {
        // A redundant setAlternateIconName call still pops the system's "You
        // have changed the icon for meow" alert, so re-tapping the current row
        // must be a no-op.
        let system = StubAlternateIcons(installed: AppIcon.leap.alternateIconName)
        let store = AppIconStore(system: system)

        #expect(await store.select(.leap))

        #expect(store.current == .leap)
        #expect(system.setCallCount == 0)
    }

    @Test
    func `select returns to primary by clearing the alternate name`() async {
        let system = StubAlternateIcons(installed: AppIcon.midnight.alternateIconName)
        let store = AppIconStore(system: system)

        #expect(await store.select(.primary))

        #expect(store.current == .primary)
        #expect(system.alternateIconName == nil)
    }

    @Test
    func `isSupported mirrors the platform capability`() {
        #expect(AppIconStore(system: StubAlternateIcons(supportsAlternateIcons: false)).isSupported == false)
        #expect(AppIconStore(system: StubAlternateIcons(supportsAlternateIcons: true)).isSupported)
    }
}

/// Stands in for `UIApplication`'s alternate-icon API — the real one mutates
/// the simulator's Home Screen and posts a system alert mid-suite.
@MainActor
private final class StubAlternateIcons: AlternateIconApplying {
    var alternateIconName: String?
    var supportsAlternateIcons: Bool
    var failure: Error?
    private(set) var setCallCount = 0

    init(installed: String? = nil, supportsAlternateIcons: Bool = true) {
        alternateIconName = installed
        self.supportsAlternateIcons = supportsAlternateIcons
    }

    func setAlternateIconName(_ name: String?) async throws {
        setCallCount += 1
        if let failure {
            throw failure
        }
        alternateIconName = name
    }
}

private struct IconChangeDeclined: Error {}
