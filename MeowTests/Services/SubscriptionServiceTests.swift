import Foundation
@testable import meow_ios
import SwiftData
import Testing

/// `SubscriptionService` coordinates fetch → detect → convert → persist. Each
/// step has its own test here; lower-level parsing coverage lives in
/// `MeowTests/Parsing/`.
@Suite("SubscriptionService", .tags(.service))
struct SubscriptionServiceTests {
    @MainActor
    private func makeService() throws -> (SubscriptionService, ModelContext) {
        let container = try ModelContainer(
            for: Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let context = ModelContext(container)
        return (SubscriptionService(modelContext: context), context)
    }

    @Test
    @MainActor
    func `updateInfo overwrites name and url and persists`() throws {
        let (service, context) = try makeService()
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
        let (service, context) = try makeService()
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

    @Test(.disabled("blocked on T4.5"))
    func `happy-path fetch returns body string`() {
        // URLProtocolStub.responses[url] = .init(body: "mixed-port: 7890\n".data)
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
    func `refresh preserves yamlBackup on first refresh`() {
        // before: yamlContent = old, yamlBackup = ""
        // after refresh: yamlContent = new, yamlBackup = old
    }

    @Test(.disabled("blocked on T4.5"))
    func `refreshAll: one failure does not poison others`() {
        // profile A stub returns 500, profile B stub returns 200
        // after refreshAll: B updated, A has lastError set, neither throws out of refreshAll
    }

    @Test(.disabled("blocked on T4.5"))
    func `deleting selected profile auto-selects next`() {
        // two profiles, delete selected, assert other becomes selected
    }
}

extension Tag {
    @Tag static var service: Self
}
