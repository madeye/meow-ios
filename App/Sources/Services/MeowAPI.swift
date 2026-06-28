import Foundation
import MeowIPC
import NetworkExtension
import os

/// REST client for the meow external-controller that runs inside the
/// packet-tunnel extension on a random loopback port. The URLSession requests
/// are issued from the main app process; iOS routes loopback traffic correctly
/// even when the tunnel is active.
@Observable
final class MeowAPI: @unchecked Sendable {
    private var baseURL: URL
    private var secret: String
    private let session: URLSession
    // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
    // Mirrors the ingress-instrumentation pattern kept around #54.
    private let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "meow-api")

    private enum URLBuildError: Error {
        case invalidComponents(endpoint: URL)
    }

    private static func buildTestDelayURL(base: URL, proxy: String, url: String, timeout: Int) throws -> URL {
        let endpoint = base.appending(path: "/proxies/\(proxy.urlEscaped)/delay")
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw URLBuildError.invalidComponents(endpoint: endpoint)
        }
        comps.queryItems = [
            .init(name: "url", value: url),
            .init(name: "timeout", value: String(timeout)),
        ]
        guard let target = comps.url else {
            throw URLBuildError.invalidComponents(endpoint: endpoint)
        }
        return target
    }

    init(
        port: Int = 0,
        secret: String = "",
        session: URLSession = .shared,
    ) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        self.session = session
    }

    /// Point the client at the port/secret the engine actually bound. On a
    /// fresh install the credential file doesn't exist when this client is
    /// first constructed (no tunnel has started), so the initial instance
    /// is intentionally unconfigured; once the extension mints credentials on
    /// connect, the app calls this to retarget before issuing requests.
    /// No-op when `port`/`secret` are unchanged.
    func updateCredentials(port: Int, secret: String) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
    }

    // MARK: - Endpoints

    func getProxies() async throws -> ProxiesResponse {
        if Self.usesMockTransport { return Self.mockProxies() }
        return try await get("/proxies")
    }

    func getConfigs() async throws -> ConfigsResponse {
        if Self.usesMockTransport { return .init(mode: "rule") }
        return try await get("/configs")
    }

    /// Updates the routing mode in the running engine. Accepts the meow
    /// wire values: `rule`, `global`, `direct`. Persists across the engine
    /// lifetime only — engine restarts reset to the YAML default.
    func setMode(_ mode: String) async throws {
        if Self.usesMockTransport { return }
        try await patch("/configs", body: ["mode": mode])
    }

    /// Switch the active member of a `type: select` proxy group.
    ///
    /// Prefers the in-process IPC path (`ProxyControlIPC` over
    /// `sendProviderMessage`), which calls `meow_proxy_select` directly
    /// against the `SelectorGroup` inside the PacketTunnel extension.
    /// That path is byte-exact: the `group` and `name` strings are
    /// matched against the parsed proxy registry without URL
    /// percent-encoding or Unicode normalization, which is what the
    /// previous loopback-HTTP path tripped on for emoji-named groups
    /// (`🚀 节点选择`) and CJK + space proxy names.
    ///
    /// Falls back to the loopback `PUT /proxies/{group}` if no provider
    /// session is available — typically when the tunnel isn't running
    /// (and the IPC would have failed anyway, but the HTTP path returns
    /// a clearer error). Set `MeowIPCDisabled = YES` in UserDefaults
    /// to force the HTTP path for debugging.
    func selectProxy(group: String, name: String) async throws {
        if Self.usesMockTransport { return }
        let ipcDisabled = UserDefaults.standard.bool(forKey: "MeowIPCDisabled")
        if !ipcDisabled, let session = await Self.tunnelSession() {
            try await selectProxyViaIPC(session: session, group: group, name: name)
            return
        }
        try await put("/proxies/\(group.urlEscaped)", body: ["name": name])
    }

    /// Single-shot request/response over `NETunnelProviderSession`.
    /// Errors here surface as `MeowAPIError.proxyControl` so the UI can
    /// distinguish "engine not running" / "name not in selector" from a
    /// transport failure.
    private func selectProxyViaIPC(
        session: NETunnelProviderSession,
        group: String,
        name: String,
    ) async throws {
        let payload = try ProxyControlIPC.encodeRequest(.select(group: group, name: name))
        #if DEBUG
            log.info("IPC proxy_select group=\(group, privacy: .public) name=\(name, privacy: .public)")
        #endif
        let response: ProxyControlResponse = try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    guard let data else {
                        cont.resume(throwing: MeowAPIError.proxyControl(reason: "no response from extension"))
                        return
                    }
                    do {
                        let decoded = try ProxyControlIPC.decodeResponse(data)
                        cont.resume(returning: decoded)
                    } catch {
                        // Bubble up enough to identify what the extension
                        // actually returned: bytes-length and a UTF-8
                        // preview (truncated). The most common shapes are
                        // empty Data (old extension binary still running
                        // post-update — disconnect/reconnect to reload),
                        // or a non-JSON status line.
                        let bytes = data.count
                        let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<non-utf8>"
                        cont.resume(throwing: MeowAPIError.proxyControl(
                            reason: "IPC reply not decodable (\(bytes) B): \(preview)",
                        ))
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
        guard response.success else {
            throw MeowAPIError.proxyControl(reason: response.errorReason ?? "unknown (code \(response.code ?? -99))")
        }
    }

    /// Resolves the running PacketTunnel session, if any. Returns nil
    /// when no manager is loaded or the tunnel isn't connected — the
    /// caller falls back to the loopback path in that case.
    private static func tunnelSession() async -> NETunnelProviderSession? {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences() else {
            return nil
        }
        return managers.first?.connection as? NETunnelProviderSession
    }

    func testDelay(proxy: String, url: String, timeout: Int = 5000) async throws -> Int {
        if Self.usesMockTransport {
            return Self.mockDelay(for: proxy)
        }

        struct Resp: Decodable { let delay: Int? }
        let target = try Self.buildTestDelayURL(base: baseURL, proxy: proxy, url: url, timeout: timeout)
        #if DEBUG
            // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
            log.info("HTTP GET \(target.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: request(for: target))
        logResponse(resp, body: data, url: target)
        return try (JSONDecoder().decode(Resp.self, from: data).delay) ?? -1
    }

    func getConnections() async throws -> ConnectionsResponse {
        if Self.usesMockTransport { return Self.mockConnections() }
        return try await get("/connections")
    }

    func closeConnection(id: String) async throws {
        if Self.usesMockTransport { return }
        try await delete("/connections/\(id)")
    }

    func closeAllConnections() async throws {
        if Self.usesMockTransport { return }
        try await delete("/connections")
    }

    func getRules() async throws -> RulesResponse {
        if Self.usesMockTransport { return Self.mockRules() }
        return try await get("/rules")
    }

    func getProviders() async throws -> ProvidersResponse {
        if Self.usesMockTransport { return Self.mockProviders() }
        return try await get("/providers/proxies")
    }

    /// Triggers meow's bulk health-check for every proxy in a provider
    /// (`GET /providers/proxies/{name}/healthcheck`). The endpoint returns
    /// 204 on success; fresh delays are surfaced on the next `getProviders()`.
    func healthCheckProvider(name: String) async throws {
        if Self.usesMockTransport { return }
        let url = baseURL.appending(path: "/providers/proxies/\(name.urlEscaped)/healthcheck")
        #if DEBUG
            // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
            log.info("HTTP GET \(url.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: request(for: url))
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    /// Stream meow logs via WebSocket with auto-reconnect.
    /// Caller owns the AsyncStream — it stops when the task is cancelled.
    func streamLogs(level: String = "info") -> AsyncThrowingStream<LogEntry, Error> {
        if Self.usesMockTransport {
            return Self.mockLogStream(level: level)
        }

        return AsyncThrowingStream { continuation in
            let log = self.log
            let task = Task {
                let url = baseURL
                    .appending(path: "/logs")
                    .appending(queryItems: [.init(name: "level", value: level)])
                var backoff: UInt64 = 1
                while !Task.isCancelled {
                    var req = URLRequest(url: url)
                    if !secret.isEmpty {
                        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                    }
                    #if DEBUG
                        log.info("WS upgrade \(url.absoluteString, privacy: .public)")
                    #endif
                    let ws = session.webSocketTask(with: req)
                    ws.resume()
                    do {
                        backoff = 1
                        while !Task.isCancelled {
                            let msg = try await ws.receive()
                            if case let .string(s) = msg {
                                #if DEBUG
                                    log.info("WS frame /logs: \(s.prefix(200), privacy: .public)")
                                #endif
                                if let entry = LogEntry.from(jsonString: s) {
                                    continuation.yield(entry)
                                }
                            }
                        }
                    } catch {
                        ws.cancel(with: .goingAway, reason: nil)
                        if Task.isCancelled { break }
                        let desc = String(describing: error)
                        log.warning("WS /logs reconnecting in \(backoff)s: \(desc, privacy: .public)")
                        try? await Task.sleep(for: .seconds(backoff))
                        backoff = min(backoff * 2, 16)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appending(path: path)
        #if DEBUG
            // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
            log.info("HTTP GET \(url.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: request(for: url))
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func put(_ path: String, body: [String: String]) async throws {
        let url = baseURL.appending(path: path)
        var req = request(for: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Body is a JSON dict from the caller — never log it; PUT bodies are
        // currently safe (proxy-name selections), but the policy is no bodies
        // because it'd leak any future credential-bearing payload.
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        #if DEBUG
            log.info("HTTP PUT \(url.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: req)
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    private func patch(_ path: String, body: [String: String]) async throws {
        let url = baseURL.appending(path: path)
        var req = request(for: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        #if DEBUG
            log.info("HTTP PATCH \(url.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: req)
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    private func delete(_ path: String) async throws {
        let url = baseURL.appending(path: path)
        var req = request(for: url)
        req.httpMethod = "DELETE"
        #if DEBUG
            log.info("HTTP DELETE \(url.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: req)
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    /// DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
    private func logResponse(_ response: URLResponse, body: Data, url: URL) {
        #if DEBUG
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: body.prefix(200), encoding: .utf8) ?? "<non-utf8 \(body.count) bytes>"
            log.info(
                "HTTP \(status, privacy: .public) from \(url.path, privacy: .public): \(preview, privacy: .public)",
            )
        #else
            _ = (response, body, url)
        #endif
    }

    private func request(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func throwIfHTTPError(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw MeowAPIError.http(status: http.statusCode)
        }
    }
}

enum MeowAPIError: Error {
    case http(status: Int)
    case malformed
    case proxyControl(reason: String)
}

private extension String {
    var urlEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

private extension MeowAPI {
    static var usesMockTransport: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    static func mockProxies() -> ProxiesResponse {
        let history: [Proxy.History] = [
            .init(time: "2026-06-28T09:40:00Z", delay: 82),
            .init(time: "2026-06-28T09:41:00Z", delay: 76),
        ]
        let singaporeHistory: [Proxy.History] = [
            .init(time: "2026-06-28T09:40:00Z", delay: 138),
            .init(time: "2026-06-28T09:41:00Z", delay: 121),
        ]
        let westHistory: [Proxy.History] = [
            .init(time: "2026-06-28T09:40:00Z", delay: 192),
            .init(time: "2026-06-28T09:41:00Z", delay: 168),
        ]
        let proxies: [String: Proxy] = [
            "GLOBAL": .init(
                name: "GLOBAL",
                type: "Selector",
                now: "Auto",
                all: ["Auto", "Tokyo 01", "Singapore 02", "US West 03", "DIRECT"],
                history: nil,
            ),
            "Proxy": .init(
                name: "Proxy",
                type: "Selector",
                now: "Auto",
                all: ["Auto", "Tokyo 01", "Singapore 02", "US West 03"],
                history: nil,
            ),
            "Auto": .init(
                name: "Auto",
                type: "URLTest",
                now: "Tokyo 01",
                all: ["Tokyo 01", "Singapore 02", "US West 03"],
                history: nil,
            ),
            "Tokyo 01": .init(name: "Tokyo 01", type: "Shadowsocks", now: nil, all: nil, history: history),
            "Singapore 02": .init(
                name: "Singapore 02",
                type: "Vmess",
                now: nil,
                all: nil,
                history: singaporeHistory,
            ),
            "US West 03": .init(name: "US West 03", type: "Trojan", now: nil, all: nil, history: westHistory),
            "DIRECT": .init(name: "DIRECT", type: "Direct", now: nil, all: nil, history: nil),
        ]
        return .init(proxies: proxies)
    }

    static func mockDelay(for proxy: String) -> Int {
        switch proxy {
        case "Tokyo 01": 76
        case "Singapore 02": 121
        case "US West 03": 168
        default: 94
        }
    }

    static func mockConnections() -> ConnectionsResponse {
        .init(
            downloadTotal: 3_842_146_304,
            uploadTotal: 486_539_264,
            connections: [
                .init(
                    id: "sim-1",
                    metadata: .init(
                        network: "tcp",
                        type: "HTTP",
                        sourceIP: "10.0.0.2",
                        destinationIP: "142.250.72.14",
                        destinationPort: "443",
                        host: "www.gstatic.com",
                    ),
                    upload: 42496,
                    download: 384_000,
                    start: "2026-06-28T09:41:00Z",
                    chains: ["Tokyo 01", "Proxy"],
                    rule: "DOMAIN-SUFFIX",
                    rulePayload: "gstatic.com",
                ),
                .init(
                    id: "sim-2",
                    metadata: .init(
                        network: "tcp",
                        type: "HTTPS",
                        sourceIP: "10.0.0.2",
                        destinationIP: "140.82.112.4",
                        destinationPort: "443",
                        host: "github.com",
                    ),
                    upload: 18944,
                    download: 96512,
                    start: "2026-06-28T09:41:07Z",
                    chains: ["Auto", "Proxy"],
                    rule: "MATCH",
                    rulePayload: "",
                ),
            ],
        )
    }

    static func mockRules() -> RulesResponse {
        .init(rules: [
            .init(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
            .init(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
            .init(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
            .init(type: "MATCH", payload: "", proxy: "Proxy"),
        ])
    }

    static func mockProviders() -> ProvidersResponse {
        let proxies = mockProxies().proxies
        let providerProxies = ["Tokyo 01", "Singapore 02", "US West 03"].compactMap { proxies[$0] }
        return .init(providers: [
            "Demo": .init(
                name: "Demo",
                type: "Proxy",
                vehicleType: "HTTP",
                proxies: providerProxies,
            ),
        ])
    }

    static func mockLogStream(level: String) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let entries = [
                LogEntry(type: level, payload: "simulator mock engine ready"),
                LogEntry(type: "debug", payload: "mock controller served /proxies"),
                LogEntry(type: "info", payload: "traffic snapshot updated"),
            ]
            let task = Task {
                var index = 0
                while !Task.isCancelled {
                    continuation.yield(entries[index % entries.count])
                    index += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
