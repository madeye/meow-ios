import Foundation
import Testing

/// Covers the `URLSession`-based client pointed at `http://127.0.0.1:9090`.
/// Tests use `URLProtocolStub` (see `MeowTests/Support/URLProtocolStub.swift`)
/// to inject canned responses.
@Suite("MihomoAPI REST client", .tags(.api))
struct MihomoAPITests {
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
}

extension Tag {
    @Tag static var api: Self
}
