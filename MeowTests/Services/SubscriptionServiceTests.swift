import Foundation
@testable import meow_ios
import MeowModels
import SwiftData
import Testing

/// `SubscriptionService` coordinates fetch → detect → convert → persist. Each
/// step has its own test here; lower-level parsing coverage lives in
/// `MeowTests/Parsing/`.
///
/// The active-config-sync tests (issue #289) cover the invariant that
/// `config.yaml` always corresponds to the selected profile, or is absent
/// when no profile is selected: refresh/edit of the selected profile
/// atomically rewrites the active file, refresh/edit of an inactive profile
/// never touches it, and deleting the selected profile clears both the
/// preference and the file. All of them use a temporary directory and an
/// isolated `UserDefaults` suite instead of the real App Group container.
@Suite("SubscriptionService", .tags(.service))
struct SubscriptionServiceTests {
    /// Everything a test needs to drive `SubscriptionService` against
    /// isolated storage: an in-memory SwiftData context, a temp-directory
    /// active-config file, and a private `UserDefaults` suite — never the
    /// real App Group container.
    private struct Harness {
        let service: SubscriptionService
        let context: ModelContext
        let configFile: URL
        let defaults: UserDefaults
    }

    @MainActor
    private func makeService(session: URLSession = .shared) throws -> Harness {
        let container = try ModelContainer(
            for: Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let context = ModelContext(container)
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "SubscriptionServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configFile = dir.appending(path: "config.yaml")
        let suiteName = "SubscriptionServiceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestSetupError.defaultsSuiteUnavailable
        }
        let service = SubscriptionService(
            modelContext: context,
            session: session,
            activeConfigDirectory: { dir },
            activeConfigURL: { configFile },
            preferences: defaults,
        )
        return Harness(service: service, context: context, configFile: configFile, defaults: defaults)
    }

    private func stubbedSession(url: String, yaml: String) -> URLSession {
        URLProtocolStub.stub(URL(string: url)!, with: .init(body: Data(yaml.utf8)))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    @Test
    @MainActor
    func `updateInfo overwrites name and url and persists`() throws {
        let harness = try makeService()
        let service = harness.service
        let context = harness.context
        let profile = Profile(name: "Old", url: "https://example.com/a.yaml", yamlContent: "mixed-port: 7890\n")
        context.insert(profile)
        try context.save()

        try service.updateInfo(profile, name: "New Name", url: "https://example.com/b.yaml")

        #expect(profile.name == "New Name")
        #expect(profile.url == "https://example.com/b.yaml")

        // Survives a fresh fetch from the same store.
        let fetched = try context.fetch(FetchDescriptor<Profile>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "New Name")
        #expect(fetched.first?.url == "https://example.com/b.yaml")
    }

    @Test
    @MainActor
    func `updateInfo trims whitespace and leaves the YAML body untouched`() throws {
        let harness = try makeService()
        let service = harness.service
        let context = harness.context
        let body = "mixed-port: 7890\nproxies: []\n"
        let profile = Profile(name: "Old", url: "", yamlContent: body)
        context.insert(profile)
        try context.save()

        // Attaching a URL to a previously local-only import promotes it.
        try service.updateInfo(profile, name: "  Trimmed  ", url: "  https://example.com/c.yaml  ")

        #expect(profile.name == "Trimmed")
        #expect(profile.url == "https://example.com/c.yaml")
        #expect(profile.yamlContent == body)
    }

    // MARK: - #289: refresh keeps config.yaml in sync only for the selected profile

    @Test
    @MainActor
    func `refresh of the selected profile atomically rewrites the active file`() async throws {
        let url = "https://example.com/selected.yaml"
        let refreshed = "proxies:\n  - name: refreshed\n    type: direct\n"
        defer { URLProtocolStub.removeStub(URL(string: url)!) }
        let harness = try makeService(session: stubbedSession(url: url, yaml: refreshed))
        let service = harness.service
        let context = harness.context
        let configFile = harness.configFile

        let profile = Profile(name: "Selected", url: url, yamlContent: "proxies: []\n", isSelected: true)
        context.insert(profile)
        try context.save()
        // Seed the active file so it starts out matching the selection.
        try service.writeActiveConfig(profile)

        try await service.refresh(profile)

        #expect(profile.yamlContent == refreshed)
        #expect(profile.yamlBackup == "proxies: []\n")
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written == refreshed)
    }

    @Test
    @MainActor
    func `refresh of an inactive profile updates SwiftData but not the active file`() async throws {
        let url = "https://example.com/inactive.yaml"
        let refreshed = "proxies:\n  - name: refreshed\n    type: direct\n"
        defer { URLProtocolStub.removeStub(URL(string: url)!) }
        let harness = try makeService(session: stubbedSession(url: url, yaml: refreshed))
        let service = harness.service
        let context = harness.context
        let configFile = harness.configFile

        let selected = Profile(name: "Selected", url: "", yamlContent: "proxies: []\n", isSelected: true)
        let inactive = Profile(name: "Other", url: url, yamlContent: "proxies: []\n")
        context.insert(selected)
        context.insert(inactive)
        try context.save()
        try service.writeActiveConfig(selected)

        try await service.refresh(inactive)

        #expect(inactive.yamlContent == refreshed)
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written == "proxies: []\n")
    }

    // MARK: - #289: editing YAML/rules only replaces config.yaml for the selected profile

    @Test
    @MainActor
    func `updateContent for the selected profile rewrites the active file`() throws {
        let harness = try makeService()
        let service = harness.service
        let context = harness.context
        let configFile = harness.configFile
        let selected = Profile(name: "Selected", url: "", yamlContent: "proxies: []\n", isSelected: true)
        context.insert(selected)
        try context.save()
        try service.writeActiveConfig(selected)

        let edited = "proxies:\n  - name: edited\n    type: direct\n"
        try service.updateContent(selected, yaml: edited)

        #expect(selected.yamlContent == edited)
        #expect(selected.yamlBackup == "proxies: []\n")
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written == edited)
    }

    @Test
    @MainActor
    func `updateContent for an inactive profile leaves the active file untouched`() throws {
        let harness = try makeService()
        let service = harness.service
        let context = harness.context
        let configFile = harness.configFile
        let selected = Profile(name: "Selected", url: "", yamlContent: "proxies: []\n", isSelected: true)
        let inactive = Profile(name: "Other", url: "", yamlContent: "proxies: []\n")
        context.insert(selected)
        context.insert(inactive)
        try context.save()
        try service.writeActiveConfig(selected)

        try service.updateContent(inactive, yaml: "proxies:\n  - name: edited\n    type: direct\n")

        #expect(inactive.yamlContent.contains("edited"))
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written == "proxies: []\n")
    }

    @Test
    @MainActor
    func `updateContent rolls back the profile when the active-file write fails`() throws {
        let container = try ModelContainer(
            for: Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let context = ModelContext(container)
        // A regular file sits where the active-config *directory* needs to be
        // created, so `FileManager.createDirectory` fails and the write never
        // happens — this exercises the rollback path rather than the happy one.
        let blockedPath = FileManager.default.temporaryDirectory
            .appending(path: "SubscriptionServiceTests-blocked-\(UUID().uuidString)")
        try Data().write(to: blockedPath)
        defer { try? FileManager.default.removeItem(at: blockedPath) }
        guard let defaults = UserDefaults(suiteName: "SubscriptionServiceTests-\(UUID().uuidString)") else {
            throw TestSetupError.defaultsSuiteUnavailable
        }
        let service = SubscriptionService(
            modelContext: context,
            activeConfigDirectory: { blockedPath },
            activeConfigURL: { blockedPath.appending(path: "config.yaml") },
            preferences: defaults,
        )
        let original = "proxies: []\n"
        let profile = Profile(name: "Selected", url: "", yamlContent: original, isSelected: true)
        context.insert(profile)
        try context.save()

        #expect(throws: (any Error).self) {
            try service.updateContent(profile, yaml: "proxies:\n  - name: x\n    type: direct\n")
        }
        // SwiftData rolled back to match the untouched (nonexistent) active file.
        #expect(profile.yamlContent == original)
        #expect(profile.yamlBackup == original)
    }

    // MARK: - #289: deleting the selected profile clears both the preference and the active file

    @Test
    @MainActor
    func `deleting the selected profile clears the preference and removes the active file`() throws {
        let harness = try makeService()
        let service = harness.service
        let context = harness.context
        let configFile = harness.configFile
        let defaults = harness.defaults
        let profile = Profile(name: "Selected", url: "", yamlContent: "proxies: []\n", isSelected: true)
        context.insert(profile)
        try context.save()
        defaults.set(profile.id.uuidString, forKey: PreferenceKey.selectedProfileID)
        try service.writeActiveConfig(profile)
        #expect(FileManager.default.fileExists(atPath: configFile.path))

        try service.delete(profile)

        #expect(defaults.string(forKey: PreferenceKey.selectedProfileID) == nil)
        #expect(!FileManager.default.fileExists(atPath: configFile.path))
        #expect(try context.fetch(FetchDescriptor<Profile>()).isEmpty)
    }

    @Test
    @MainActor
    func `deleting an inactive profile leaves the preference and active file untouched`() throws {
        let harness = try makeService()
        let service = harness.service
        let context = harness.context
        let configFile = harness.configFile
        let defaults = harness.defaults
        let selected = Profile(name: "Selected", url: "", yamlContent: "proxies: []\n", isSelected: true)
        let other = Profile(name: "Other", url: "", yamlContent: "proxies: []\n")
        context.insert(selected)
        context.insert(other)
        try context.save()
        defaults.set(selected.id.uuidString, forKey: PreferenceKey.selectedProfileID)
        try service.writeActiveConfig(selected)

        try service.delete(other)

        #expect(defaults.string(forKey: PreferenceKey.selectedProfileID) == selected.id.uuidString)
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written == "proxies: []\n")
        #expect(try context.fetch(FetchDescriptor<Profile>()).count == 1)
    }

    @Test(.disabled("blocked on T4.5"))
    func `happy-path fetch returns body string`() {
        // URLProtocolStub.stub(url, with: .init(body: "mixed-port: 7890\n".data))
        // let body = try await service.fetchSubscription(url: url)
        // #expect(body.contains("mixed-port"))
    }

    @Test(.disabled("blocked on T4.5"))
    func `HTTP 404 surfaces a specific error`() {
        // #expect throws SubscriptionError.httpStatus(404)
    }

    @Test(.disabled("blocked on T4.5"))
    func `fetch timeout after 30s`() {
        // URLProtocolStub response with .error(NSURLErrorTimedOut)
    }

    @Test(.disabled("blocked on T4.5"))
    func `addProfile rejects duplicate URL`() {
        // expect throws SubscriptionError.duplicateURL
    }

    @Test(.disabled("blocked on T4.5"))
    func `refreshAll: one failure does not poison others`() {
        // profile A stub returns 500, profile B stub returns 200
        // after refreshAll: B updated, A has lastError set, neither throws out of refreshAll
    }
}

private enum TestSetupError: Error {
    case defaultsSuiteUnavailable
}

extension Tag {
    @Tag static var service: Self
}
