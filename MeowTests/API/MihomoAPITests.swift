import Testing
import Foundation

/// Covers the `URLSession`-based client pointed at `http://127.0.0.1:9090`.
/// Tests use `URLProtocolStub` (see `MeowTests/Support/URLProtocolStub.swift`)
/// to inject canned responses.
@Suite("MihomoAPI REST client", .tags(.api))
struct MihomoAPITests {

    @Test("GET /proxies parses groups and nested proxies", .disabled("blocked on T4.4"))
    func testGetProxies() async throws {
        // stub response: {"proxies": {"Proxy": {"type":"Selector", "all":["a","b"], "now":"a"}, ...}}
    }

    @Test("PUT /proxies/{name} body serializes selection", .disabled("blocked on T4.4"))
    func testSelectProxyBody() async throws {
        // call selectProxy(group: "Proxy", name: "node-01"); inspect captured request body
    }

    @Test("GET /connections handles 1000-entry payload", .disabled("blocked on T4.4"))
    func testConnectionsLargePayload() async throws {
        // generate fixture with 1000 connections, assert parse time < 100ms
    }

    @Test("DELETE /connections/{id}", .disabled("blocked on T4.4"))
    func testCloseConnection() async throws {
        // verify correct HTTP verb and path
    }

    @Test("GET /configs returns current config", .disabled("blocked on T4.4"))
    func testGetConfigs() async throws {}

    @Test("PATCH /configs updates route mode", .disabled("blocked on T4.4"))
    func testPatchConfigsMode() async throws {
        // body {"mode":"global"} serialized correctly
    }

    @Test("GET /proxies/{name}/delay returns ms on success", .disabled("blocked on T4.4"))
    func testDelaySuccess() async throws {
        // stub 200 {"delay": 123}
    }

    @Test("GET /proxies/{name}/delay timeout → specific error", .disabled("blocked on T4.4"))
    func testDelayTimeout() async throws {
        // stub NSURLErrorTimedOut
    }

    @Test("streamLogs yields LogEntry values from WebSocket", .disabled("blocked on T4.4 + WebSocket stubbing"))
    func testStreamLogs() async throws {
        // requires URLSessionWebSocketTask stubbing — follow-up if test infra too heavy
    }
}

extension Tag {
    @Tag static var api: Self
}
