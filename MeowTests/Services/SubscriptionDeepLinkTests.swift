import Foundation
@testable import meow_ios
import Testing

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
    @Test
    func `accepts well-formed meow://connect with http(s) url`() throws {
        let link = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml")),
        ))
        #expect(link.subscriptionURL == URL(string: "https://example.com/sub.yaml"))
        #expect(link.name == "example.com")
        #expect(link.autoSelect == false)
    }

    @Test
    func `http subscription urls are accepted (not every user has TLS)`() throws {
        let link = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=http%3A%2F%2F10.0.0.1%2Fsub.yaml")),
        ))
        #expect(link.subscriptionURL.scheme == "http")
    }

    @Test
    func `explicit name query parameter overrides host-derived default`() throws {
        let link = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fsub.yaml&name=My%20VPN")),
        ))
        #expect(link.name == "My VPN")
    }

    @Test
    func `select=1 opts in to auto-select; absent or any other value stays off`() throws {
        let on = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs&select=1")),
        ))
        #expect(on.autoSelect)

        let absent = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs")),
        ))
        #expect(absent.autoSelect == false)

        let wrongValue = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fe.com%2Fs&select=yes")),
        ))
        #expect(wrongValue.autoSelect == false)
    }

    @Test
    func `rejects wrong host — only meow://connect is this handler's business`() throws {
        #expect(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://diagnostics?url=https%3A%2F%2Fe.com%2Fs")),
        ) == nil)
        #expect(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://random?url=https%3A%2F%2Fe.com%2Fs")),
        ) == nil)
    }

    @Test
    func `rejects wrong scheme — https://connect is not our URL scheme`() throws {
        #expect(try SubscriptionDeepLink.parse(
            #require(URL(string: "https://connect?url=https%3A%2F%2Fe.com%2Fs")),
        ) == nil)
    }

    @Test
    func `rejects missing ?url= entirely`() throws {
        #expect(try SubscriptionDeepLink.parse(#require(URL(string: "meow://connect"))) == nil)
        #expect(try SubscriptionDeepLink.parse(#require(URL(string: "meow://connect?name=foo"))) == nil)
    }

    @Test
    func `rejects empty ?url= value`() throws {
        #expect(try SubscriptionDeepLink.parse(#require(URL(string: "meow://connect?url="))) == nil)
    }

    @Test
    func `rejects non-http(s) schemes to block file:/data: smuggling`() throws {
        let cases = [
            "file%3A%2F%2F%2Fetc%2Fpasswd",
            "data%3Atext%2Fplain%2Chello",
            "javascript%3Aalert(1)",
            "ftp%3A%2F%2Fexample.com%2Fs",
        ]
        for encoded in cases {
            let url = try #require(URL(string: "meow://connect?url=\(encoded)"))
            #expect(SubscriptionDeepLink.parse(url) == nil,
                    "expected rejection for \(url.absoluteString)")
        }
    }

    @Test
    func `rejects http url with empty host`() throws {
        #expect(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2F%2Fsub.yaml")),
        ) == nil)
    }

    @Test
    func `blank explicit name falls back to host-derived default`() throws {
        let link = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fs&name=")),
        ))
        #expect(link.name == "example.com")

        let whitespace = try #require(try SubscriptionDeepLink.parse(
            #require(URL(string: "meow://connect?url=https%3A%2F%2Fexample.com%2Fs&name=%20%20%20")),
        ))
        #expect(whitespace.name == "example.com")
    }
}

extension Tag {
    @Tag static var deepLink: Self
}
