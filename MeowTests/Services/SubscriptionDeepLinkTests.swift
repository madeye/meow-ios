import Testing
import Foundation
@testable import meow_ios

/// `meow://connect?url=<encoded>` deep-link parsing. The app-side
/// handler (`ContentView.onOpenURL`) only branches on
/// `SubscriptionDeepLink.parse(_:) != nil`, so every acceptance /
/// rejection decision must happen here.
///
/// PRD §4.3 Subscriptions — subscription import must tolerate the
/// common share-sheet shape (URL-encoded subscription link, optional
/// friendly name) while rejecting anything that could be used to
/// smuggle a non-remote YAML source.
@Suite("SubscriptionDeepLink.parse", .tags(.deepLink))
struct SubscriptionDeepLinkTests {

    @Test("accepts well-formed meow://connect with http(s) url")
    func acceptsHappyPath() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml")!
        ))
        #expect(link.subscriptionURL == URL(string: "https://example.com/sub.yaml"))
        #expect(link.name == "example.com")
        #expect(link.autoSelect == false)
    }

    @Test("http subscription urls are accepted (not every user has TLS)")
    func acceptsHTTPScheme() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=http%3A%2F%2F10.0.0.1%2Fsub.yaml")!
        ))
        #expect(link.subscriptionURL.scheme == "http")
    }

    @Test("explicit name query parameter overrides host-derived default")
    func explicitNameWins() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml&name=My%20VPN")!
        ))
        #expect(link.name == "My VPN")
    }

    @Test("select=1 opts in to auto-select; absent or any other value stays off")
    func autoSelectOptIn() throws {
        let on = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs&select=1")!
        ))
        #expect(on.autoSelect)

        let absent = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs")!
        ))
        #expect(absent.autoSelect == false)

        let wrongValue = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs&select=yes")!
        ))
        #expect(wrongValue.autoSelect == false)
    }

    @Test("rejects wrong host — only meow://connect is this handler's business")
    func rejectsWrongHost() {
        #expect(SubscriptionDeepLink.parse(
            URL(string: "meow://diagnostics?url=https%3A%2F%2Fe.com%2Fs")!
        ) == nil)
        #expect(SubscriptionDeepLink.parse(
            URL(string: "meow://random?url=https%3A%2F%2Fe.com%2Fs")!
        ) == nil)
    }

    @Test("rejects wrong scheme — https://connect is not our URL scheme")
    func rejectsWrongScheme() {
        #expect(SubscriptionDeepLink.parse(
            URL(string: "https://connect?url=https%3A%2F%2Fe.com%2Fs")!
        ) == nil)
    }

    @Test("rejects missing ?url= entirely")
    func rejectsMissingURL() {
        #expect(SubscriptionDeepLink.parse(URL(string: "meow://connect")!) == nil)
        #expect(SubscriptionDeepLink.parse(URL(string: "meow://connect?name=foo")!) == nil)
    }

    @Test("rejects empty ?url= value")
    func rejectsEmptyURL() {
        #expect(SubscriptionDeepLink.parse(URL(string: "meow://connect?url=")!) == nil)
    }

    @Test("rejects non-http(s) schemes to block file:/data: smuggling")
    func rejectsDangerousSchemes() {
        let cases = [
            "file%3A%2F%2F%2Fetc%2Fpasswd",
            "data%3Atext%2Fplain%2Chello",
            "javascript%3Aalert(1)",
            "ftp%3A%2F%2Fexample.com%2Fs",
        ]
        for encoded in cases {
            let url = URL(string: "meow://connect?url=\(encoded)")!
            #expect(SubscriptionDeepLink.parse(url) == nil,
                    "expected rejection for \(url.absoluteString)")
        }
    }

    @Test("rejects http url with empty host")
    func rejectsEmptyHost() {
        #expect(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2F%2Fsub.yaml")!
        ) == nil)
    }

    @Test("blank explicit name falls back to host-derived default")
    func blankNameFallsBack() throws {
        let link = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fs&name=")!
        ))
        #expect(link.name == "example.com")

        let whitespace = try #require(SubscriptionDeepLink.parse(
            URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fs&name=%20%20%20")!
        ))
        #expect(whitespace.name == "example.com")
    }
}

extension Tag {
    @Tag static var deepLink: Self
}
