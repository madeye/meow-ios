import Foundation
import Testing

/// Subscription URL ingress validator. Ship-blocker: must reject any scheme
/// outside http(s).
@Suite("Subscription URL validator", .tags(.security))
struct URLValidationTests {
    @Test(.disabled("blocked on validator implementation"))
    func `accepts https URLs`() {
        // #expect(SubscriptionURL.validate("https://example.com/sub") == .valid)
    }

    @Test(.disabled("blocked on validator"))
    func `accepts http URLs with warning`() {
        // #expect(SubscriptionURL.validate("http://example.com") == .insecureHttp)
    }

    @Test(.disabled("blocked on validator"))
    func `rejects file:// scheme`() {
        // #expect(SubscriptionURL.validate("file:///etc/passwd") == .unsupportedScheme)
    }

    @Test(.disabled("blocked on validator"))
    func `rejects javascript: scheme`() {
        // ship-blocker
    }

    @Test(.disabled("blocked on validator"))
    func `rejects data: scheme`() {
        // ship-blocker — would let base64-smuggled payloads bypass controls
    }

    @Test(.disabled("blocked on validator"))
    func `rejects malformed URL strings`() {
        // "not a url", "", " " all rejected
    }
}
