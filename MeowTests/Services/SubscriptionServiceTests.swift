import Testing
import Foundation

/// `SubscriptionService` coordinates fetch → detect → convert → persist. Each
/// step has its own test here; lower-level parsing coverage lives in
/// `MeowTests/Parsing/`.
@Suite("SubscriptionService", .tags(.service))
struct SubscriptionServiceTests {

    @Test("happy-path fetch returns body string", .disabled("blocked on T4.5"))
    func testFetchHappyPath() async throws {
        // URLProtocolStub.responses[url] = .init(body: "mixed-port: 7890\n".data)
        // let body = try await service.fetchSubscription(url: url)
        // #expect(body.contains("mixed-port"))
    }

    @Test("HTTP 404 surfaces a specific error", .disabled("blocked on T4.5"))
    func testFetch404() async throws {
        // #expect throws SubscriptionError.httpStatus(404)
    }

    @Test("fetch timeout after 30s", .disabled("blocked on T4.5"))
    func testFetchTimeout() async throws {
        // URLProtocolStub response with .error(NSURLErrorTimedOut)
    }

    @Test("addProfile rejects duplicate URL", .disabled("blocked on T4.5"))
    func testAddProfileDuplicate() async throws {
        // expect throws SubscriptionError.duplicateURL
    }

    @Test("refresh preserves yamlBackup on first refresh", .disabled("blocked on T4.5"))
    func testRefreshPreservesBackup() async throws {
        // before: yamlContent = old, yamlBackup = ""
        // after refresh: yamlContent = new, yamlBackup = old
    }

    @Test("refreshAll: one failure does not poison others", .disabled("blocked on T4.5"))
    func testRefreshAllPartialFailure() async throws {
        // profile A stub returns 500, profile B stub returns 200
        // after refreshAll: B updated, A has lastError set, neither throws out of refreshAll
    }

    @Test("deleting selected profile auto-selects next", .disabled("blocked on T4.5"))
    func testDeleteSelectedAutoSelectsNext() async throws {
        // two profiles, delete selected, assert other becomes selected
    }
}

extension Tag {
    @Tag static var service: Self
}
