import Foundation
@testable import meow_ios
import SwiftData
import Testing

/// Issue #293 — a `meow://connect` deep link must never fetch or activate a
/// subscription without an explicit in-app decision. `SubscriptionDeepLinkTests`
/// covers URL parsing; this suite covers what happens next: turning a parsed
/// link into a `DeepLinkImportConfirmation` (host / name / HTTPS / duplicate
/// detection — pure, no networking) and reducing the user's choice through
/// `DeepLinkImportCoordinator` (cancel is a no-op, import-only never
/// activates, import-and-activate does, replays update in place).
@Suite("DeepLinkImportConfirmation", .tags(.deepLink))
struct DeepLinkImportConfirmationTests {
    // MARK: - make(for:existingProfiles:)

    @Test
    func `https link with no existing profile is not insecure and not a duplicate`() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml&name=My%20VPN")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        #expect(confirmation.host == "example.com")
        #expect(confirmation.name == "My VPN")
        #expect(confirmation.isInsecure == false)
        #expect(confirmation.isDuplicate == false)
        #expect(confirmation.existingProfileID == nil)
    }

    @Test
    func `http link is flagged insecure`() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=http%3A%2F%2F10.0.0.1%2Fsub.yaml")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        #expect(confirmation.isInsecure)
    }

    @Test
    func `select=1 sets requestsActivation but does not itself activate anything`() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs&select=1")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        #expect(confirmation.requestsActivation)
    }

    @Test
    func `absent select= means the confirmation never offers Import & Activate`() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        #expect(confirmation.requestsActivation == false)
    }

    @Test
    func `a profile with the same subscription URL is detected as a duplicate`() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml")!,
        ))
        let existingID = UUID()
        let confirmation = DeepLinkImportConfirmation.make(
            for: link,
            existingProfiles: [(id: existingID, url: "https://example.com/sub.yaml")],
        )

        #expect(confirmation.isDuplicate)
        #expect(confirmation.existingProfileID == existingID)
    }

    @Test
    func `a different subscription URL is not treated as a duplicate`() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(
            for: link,
            existingProfiles: [(id: UUID(), url: "https://example.com/other.yaml")],
        )

        #expect(confirmation.isDuplicate == false)
    }

    // MARK: - DeepLinkImportCoordinator

    @MainActor
    private func makeCoordinator() throws -> (DeepLinkImportCoordinator, ModelContext) {
        let container = try ModelContainer(
            for: Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let context = ModelContext(container)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: config)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DeepLinkImportConfirmationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard let defaults = UserDefaults(suiteName: "DeepLinkImportConfirmationTests-\(UUID().uuidString)") else {
            throw DeepLinkTestSetupError.defaultsSuiteUnavailable
        }
        let service = SubscriptionService(
            modelContext: context,
            session: session,
            activeConfigDirectory: { directory },
            activeConfigURL: { directory.appending(path: "config.yaml") },
            preferences: defaults,
        )
        return (DeepLinkImportCoordinator(subscriptionService: service), context)
    }

    @Test
    @MainActor
    func `cancel does nothing — no fetch, no persisted profile`() async throws {
        let (coordinator, context) = try makeCoordinator()
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        let result = try await coordinator.resolve(confirmation, action: .cancel, existingProfile: nil)

        #expect(result == nil)
        #expect(try context.fetch(FetchDescriptor<Profile>()).isEmpty)
    }

    @Test
    @MainActor
    func `import-only fetches and persists a new profile without selecting it`() async throws {
        let (coordinator, context) = try makeCoordinator()
        // Unique URL per test: stubs are process-global and tests run
        // concurrently, so sharing one URL races bodies across tests.
        let remote = URL(string: "https://example.com/import-only.yaml")!
        URLProtocolStub.stub(remote, with: .init(body: Data("proxies: []\nproxy-groups: []\n".utf8)))
        defer { URLProtocolStub.removeStub(remote) }

        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fimport-only.yaml&select=1")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        let profile = try await coordinator.resolve(confirmation, action: .importOnly, existingProfile: nil)

        let saved = try context.fetch(FetchDescriptor<Profile>())
        #expect(saved.count == 1)
        #expect(saved.first?.url == remote.absoluteString)
        // select=1 was present on the link, but the user chose import-only —
        // it must not be activated.
        #expect(profile?.isSelected == false)
        #expect(saved.first?.isSelected == false)
    }

    @Test
    @MainActor
    func `import-and-activate fetches, persists, and selects the profile`() async throws {
        let (coordinator, context) = try makeCoordinator()
        let remote = URL(string: "https://example.com/import-activate.yaml")!
        URLProtocolStub.stub(remote, with: .init(body: Data("proxies: []\nproxy-groups: []\n".utf8)))
        defer { URLProtocolStub.removeStub(remote) }

        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fimport-activate.yaml&select=1")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        let profile = try await coordinator.resolve(confirmation, action: .importAndActivate, existingProfile: nil)

        #expect(profile?.isSelected == true)
        let saved = try context.fetch(FetchDescriptor<Profile>())
        #expect(saved.count == 1)
        #expect(saved.first?.isSelected == true)
    }

    @Test
    @MainActor
    func `importAndActivate without select=1 on the confirmation still does not activate`() async throws {
        // Defense in depth: even if a caller passes .importAndActivate for a
        // confirmation that never offered it (no select=1 on the link), the
        // coordinator refuses to select the profile.
        let (coordinator, context) = try makeCoordinator()
        let remote = URL(string: "https://example.com/no-select.yaml")!
        URLProtocolStub.stub(remote, with: .init(body: Data("proxies: []\nproxy-groups: []\n".utf8)))
        defer { URLProtocolStub.removeStub(remote) }

        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fno-select.yaml")!,
        ))
        #expect(link.autoSelect == false)
        let confirmation = DeepLinkImportConfirmation.make(for: link, existingProfiles: [])

        let profile = try await coordinator.resolve(confirmation, action: .importAndActivate, existingProfile: nil)

        #expect(profile?.isSelected == false)
        let saved = try context.fetch(FetchDescriptor<Profile>())
        #expect(saved.first?.isSelected == false)
    }

    @Test
    @MainActor
    func `replaying a deep link for an already-imported URL updates in place instead of duplicating`() async throws {
        let (coordinator, context) = try makeCoordinator()
        let remote = "https://example.com/replay.yaml"
        let existing = Profile(name: "Old Name", url: remote, yamlContent: "proxies: []\nproxy-groups: []\n")
        context.insert(existing)
        try context.save()

        URLProtocolStub.stub(
            URL(string: remote)!,
            with: .init(body: Data("proxies: []\nproxy-groups: []\n# refreshed\n".utf8)),
        )
        defer { URLProtocolStub.removeStub(URL(string: remote)!) }

        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Freplay.yaml")!,
        ))
        let confirmation = DeepLinkImportConfirmation.make(
            for: link,
            existingProfiles: [(id: existing.id, url: remote)],
        )
        #expect(confirmation.isDuplicate)

        let profile = try await coordinator.resolve(
            confirmation,
            action: .importOnly,
            existingProfile: existing,
        )

        // Same profile, refreshed content — not a second row.
        let saved = try context.fetch(FetchDescriptor<Profile>())
        #expect(saved.count == 1)
        #expect(profile?.id == existing.id)
        #expect(saved.first?.name == "Old Name")
        #expect(saved.first?.yamlContent.contains("# refreshed") == true)
    }
}

private enum DeepLinkTestSetupError: Error {
    case defaultsSuiteUnavailable
}
