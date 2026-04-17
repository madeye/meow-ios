import Foundation
import Testing

/// `SubscriptionService` coordinates fetch → detect → convert → persist. Each
/// step has its own test here; lower-level parsing coverage lives in
/// `MeowTests/Parsing/`.
@Suite("SubscriptionService", .tags(.service))
struct SubscriptionServiceTests {
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
