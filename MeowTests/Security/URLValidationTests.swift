import Testing
import Foundation

/// Subscription URL ingress validator. Ship-blocker: must reject any scheme
/// outside http(s).
@Suite("Subscription URL validator", .tags(.security))
struct URLValidationTests {

    @Test("accepts https URLs", .disabled("blocked on validator implementation"))
    func testAcceptsHttps() {
        // #expect(SubscriptionURL.validate("https://example.com/sub") == .valid)
    }

    @Test("accepts http URLs with warning", .disabled("blocked on validator"))
    func testAcceptsHttpWithWarning() {
        // #expect(SubscriptionURL.validate("http://example.com") == .insecureHttp)
    }

    @Test("rejects file:// scheme", .disabled("blocked on validator"))
    func testRejectsFile() {
        // #expect(SubscriptionURL.validate("file:///etc/passwd") == .unsupportedScheme)
    }

    @Test("rejects javascript: scheme", .disabled("blocked on validator"))
    func testRejectsJavascript() {
        // ship-blocker
    }

    @Test("rejects data: scheme", .disabled("blocked on validator"))
    func testRejectsData() {
        // ship-blocker — would let base64-smuggled payloads bypass controls
    }

    @Test("rejects malformed URL strings", .disabled("blocked on validator"))
    func testRejectsMalformed() {
        // "not a url", "", " " all rejected
    }
}
