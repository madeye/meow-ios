import Foundation
@testable import meow_ios
import Testing

/// Covers the `URLSession`-based client pointed at the engine's loopback REST API.
/// Tests use `URLProtocolStub` (see `MeowTests/Support/URLProtocolStub.swift`)
/// to inject canned responses.
@Suite("MeowAPI REST client", .tags(.api))
struct MeowAPITests {
    @Test(.disabled("blocked on T4.4"))
    func `GET /proxies parses groups and nested proxies`() {
        // stub response: {"proxies": {"Proxy": {"type":"Selector", "all":["a","b"], "now":"a"}, ...}}
    }

    @Test(.disabled("blocked on T4.4"))
    func `PUT /proxies/{name} body serializes selection`() {
        // call selectProxy(group: "Proxy", name: "node-01"); inspect captured request body
    }

    @Test(.disabled("blocked on T4.4"))
    func `GET /connections handles 1000-entry payload`() {
        // generate fixture with 1000 connections, assert parse time < 100ms
    }

    @Test(.disabled("blocked on T4.4"))
    func `DELETE /connections/{id}`() {
        // verify correct HTTP verb and path
    }

    @Test(.disabled("blocked on T4.4"))
    func `GET /configs returns current config`() {}

    @Test(.disabled("blocked on T4.4"))
    func `PATCH /configs updates route mode`() {
        // body {"mode":"global"} serialized correctly
    }

    @Test(.disabled("blocked on T4.4"))
    func `GET /proxies/{name}/delay returns ms on success`() {
        // stub 200 {"delay": 123}
    }

    @Test(.disabled("blocked on T4.4"))
    func `GET /proxies/{name}/delay timeout → specific error`() {
        // stub NSURLErrorTimedOut
    }

    @Test(.disabled("blocked on T4.4 + WebSocket stubbing"))
    func `streamLogs yields LogEntry values from WebSocket`() {
        // requires URLSessionWebSocketTask stubbing — follow-up if test infra too heavy
    }

    /// Regression test for #290: a fresh install starts `streamLogs` against
    /// port 0 (no API credentials minted yet). The stream's reconnect loop
    /// used to compute its target URL once before the retry loop, so once
    /// `updateCredentials` retargeted the client (first tunnel connect), every
    /// subsequent retry kept hitting the stale `127.0.0.1:0/logs` forever and
    /// the Logs utility only recovered on relaunch.
    ///
    /// Injects a `webSocketTaskFactory` (see `MeowAPI`) that immediately fails
    /// every connection attempt, so the retry loop cycles quickly. Asserts
    /// that the request recorded AFTER `updateCredentials` targets the new
    /// port/secret, proving each retry iteration re-reads current credentials
    /// instead of a URL captured once up front.
    @Test
    func `streamLogs retargets to updated credentials on next retry`() async throws {
        let recorder = WebSocketRequestRecorder()
        let api = MeowAPI(
            port: 0,
            secret: "",
            session: .shared,
            webSocketTaskFactory: { request in
                recorder.record(request)
                return ImmediatelyFailingWebSocketTransport()
            },
        )

        let stream = api.streamLogs(level: "debug")
        let consumer = Task {
            for try await _ in stream {}
        }
        defer { consumer.cancel() }

        // First attempt: unconfigured client, still pointed at port 0.
        while recorder.count < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let first = try #require(recorder.request(at: 0))
        #expect(first.url?.absoluteString.contains("127.0.0.1:0/logs") == true)

        // Simulate the engine minting real credentials on first tunnel connect.
        api.updateCredentials(port: 54321, secret: "s3cr3t-token")

        // Next retry (after the loop's backoff sleep) must target the new
        // port/secret rather than replaying the pre-update URL.
        while recorder.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let second = try #require(recorder.request(at: 1))
        #expect(second.url?.absoluteString.contains("127.0.0.1:54321/logs") == true)
        #expect(second.value(forHTTPHeaderField: "Authorization") == "Bearer s3cr3t-token")
    }
}

extension Tag {
    @Tag static var api: Self
}
