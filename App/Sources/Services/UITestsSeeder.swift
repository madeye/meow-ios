#if DEBUG
import Foundation
import SwiftData
import MeowModels

/// Seeds a minimal Clash profile into SwiftData + the App Group container
/// when the app is launched under XCUITest with `-UITests`. The fixture is
/// bundled as `UITestsFixtureProfile.yaml` (see `App/Resources`).
///
/// Scope: this is Option 2 of the LocalE2ETests ladder. On a cold sim, the
/// VPN toggle is disabled until a profile is selected, which meant the
/// `testToggleMovesBadgeToConnecting` test had to `XCTSkip`. Running this
/// seeder before `VpnManager.refresh()` means the toggle is live and the
/// diagnostics panel's `TUN_EXISTS` / `MEM_OK` checks can be asserted
/// locally without standing up the Tart vphone fixture.
///
/// `#if DEBUG` keeps the seeder out of Release builds — no chance of a
/// release build silently picking up a fixture profile.
enum UITestsSeeder {
    static let launchArg = "-UITests"
    static let fixtureName = "UITests Fixture"
    static let fixtureResource = "UITestsFixtureProfile"
    static let fixtureURLPlaceholder = "meow://ui-tests-fixture"

    static func seedIfNeeded(modelContext: ModelContext) {
        guard CommandLine.arguments.contains(launchArg) else { return }
        guard let yaml = loadBundledYAML() else {
            NSLog("UITestsSeeder: %@.yaml missing from bundle — skipping seed", fixtureResource)
            return
        }

        do {
            try upsertProfile(yaml: yaml, modelContext: modelContext)
            try writeActiveConfig(yaml: yaml)
        } catch {
            NSLog("UITestsSeeder: seed failed: %@", String(describing: error))
        }
    }

    private static func loadBundledYAML() -> String? {
        guard let url = Bundle.main.url(forResource: fixtureResource, withExtension: "yaml") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func upsertProfile(yaml: String, modelContext: ModelContext) throws {
        let existing = try modelContext.fetch(FetchDescriptor<Profile>())
        let fixture = existing.first { $0.name == fixtureName }
            ?? {
                let p = Profile(
                    name: fixtureName,
                    url: fixtureURLPlaceholder,
                    yamlContent: yaml,
                    yamlBackup: yaml
                )
                modelContext.insert(p)
                return p
            }()
        fixture.yamlContent = yaml
        fixture.yamlBackup = yaml
        for p in existing where p.id != fixture.id { p.isSelected = false }
        fixture.isSelected = true
        AppGroup.defaults.set(fixture.id.uuidString, forKey: PreferenceKey.selectedProfileID)
        try modelContext.save()
    }

    private static func writeActiveConfig(yaml: String) throws {
        let dir = AppGroup.containerURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: AppGroup.configURL, atomically: true, encoding: .utf8)
    }
}
#endif
