import Foundation
import MeowIPC
import NetworkExtension
import os

/// Seam over `URLSessionWebSocketTask` so `streamLogs`'s reconnect loop can be
/// driven by a fake transport in tests (see `MeowAPITests`) without opening a
/// real socket. `URLSessionWebSocketTask` already satisfies this shape, so no
/// wrapper type is needed on the production path — see the `extension` below.
protocol MeowWebSocketTransport: Sendable {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: MeowWebSocketTransport {}

/// Thread-safe holder for the mutable port/secret credentials the engine
/// mints once the tunnel connects (see `MeowAPI.updateCredentials`). On a
/// fresh install `MeowAPI` starts unconfigured (port 0); every request, and
/// each `streamLogs` reconnect iteration, reads a fresh `baseURL`/`secret`/
/// `snapshot` here instead of caching one, so a credential update retargets
/// in-flight requests and streams instead of leaving them pinned to the old
/// port forever (#290).
private final class MeowAPICredentials: @unchecked Sendable {
    private struct Values {
        var baseURL: URL
        var secret: String
    }

    private let lock: OSAllocatedUnfairLock<Values>

    init(port: Int, secret: String) {
        lock = OSAllocatedUnfairLock(initialState: Values(baseURL: Self.url(forPort: port), secret: secret))
    }

    var baseURL: URL {
        lock.withLock { $0.baseURL }
    }

    var secret: String {
        lock.withLock { $0.secret }
    }

    var snapshot: (baseURL: URL, secret: String) {
        lock.withLock { ($0.baseURL, $0.secret) }
    }

    func update(port: Int, secret: String) {
        lock.withLock { $0 = Values(baseURL: Self.url(forPort: port), secret: secret) }
    }

    private static func url(forPort port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}

/// REST client for the meow external-controller that runs inside the
/// packet-tunnel extension on a random loopback port. The URLSession requests
/// are issued from the main app process; iOS routes loopback traffic correctly
/// even when the tunnel is active.
@Observable
final class MeowAPI: @unchecked Sendable {
    private let credentials: MeowAPICredentials
    private let session: URLSession
    /// Creates the transport for `streamLogs`'s WebSocket upgrade. Defaults to
    /// `session.webSocketTask(with:)`; tests inject a fake transport to
    /// observe reconnect attempts without a real socket.
    private let webSocketTaskFactory: @Sendable (URLRequest) -> MeowWebSocketTransport
    private let usesInjectedWebSocketTransport: Bool
    // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
    // Mirrors the ingress-instrumentation pattern kept around #54.
    private let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "meow-api")

    private enum URLBuildError: Error {
        case invalidComponents(endpoint: URL)
    }

    private static func buildTestDelayURL(base: URL, path: String, url: String, timeout: Int) throws -> URL {
        let endpoint = base.appending(path: path)
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
        webSocketTaskFactory: (@Sendable (URLRequest) -> MeowWebSocketTransport)? = nil,
    ) {
        credentials = MeowAPICredentials(port: port, secret: secret)
        self.session = session
        usesInjectedWebSocketTransport = webSocketTaskFactory != nil
        self.webSocketTaskFactory = webSocketTaskFactory ?? { req in session.webSocketTask(with: req) }
    }

    /// Point the client at the port/secret the engine actually bound. On a
    /// fresh install the credential file doesn't exist when this client is
    /// first constructed (no tunnel has started), so the initial instance
    /// is intentionally unconfigured; once the extension mints credentials on
    /// connect, the app calls this to retarget before issuing requests.
    ///
    /// Safe to call while `streamLogs`'s reconnect loop is running: the loop
    /// recomputes its target from `credentials` on every retry iteration
    /// (never once up front), so an in-flight socket's *next* reconnect
    /// attempt — after its current attempt fails or is torn down — picks up
    /// the new port/secret without needing an app relaunch.
    func updateCredentials(port: Int, secret: String) {
        credentials.update(port: port, secret: secret)
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
        let target = try Self.buildTestDelayURL(
            base: credentials.baseURL,
            path: "/proxies/\(proxy.urlEscaped)/delay",
            url: url,
            timeout: timeout,
        )
        #if DEBUG
            // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
            log.info("HTTP GET \(target.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: request(for: target))
        logResponse(resp, body: data, url: target)
        return try (JSONDecoder().decode(Resp.self, from: data).delay) ?? -1
    }

    /// Batch delay test for every member of a proxy group
    /// (`GET /group/{name}/delay`). The engine probes members with bounded
    /// concurrency (16) under a *single* `timeout` budget for the whole
    /// batch — hence the larger default than the per-proxy test — and
    /// records each outcome in the proxy's delay history, so callers
    /// refresh `/proxies` afterwards to pick up the new badges. Returns
    /// the name → delay map; a whole-batch overrun surfaces as
    /// `MeowAPIError.http(status: 504)` even when some members completed.
    @discardableResult
    func testGroupDelay(group: String, url: String, timeout: Int = 10000) async throws -> [String: Int] {
        if Self.usesMockTransport {
            return Self.mockGroupDelay(for: group)
        }

        let target = try Self.buildTestDelayURL(
            base: credentials.baseURL,
            path: "/group/\(group.urlEscaped)/delay",
            url: url,
            timeout: timeout,
        )
        #if DEBUG
            // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
            log.info("HTTP GET \(target.absoluteString, privacy: .public)")
        #endif
        let (data, resp) = try await session.data(for: request(for: target))
        logResponse(resp, body: data, url: target)
        try throwIfHTTPError(resp)
        return try JSONDecoder().decode([String: Int].self, from: data)
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

    func getDnsResults(search: String? = nil, limit: Int = 256) async throws -> [DnsResult] {
        if Self.usesMockTransport { return Self.mockDnsResults(search: search) }
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        return try await get("/dns/results", queryItems: queryItems)
    }

    /// Triggers meow's bulk health-check for every proxy in a provider
    /// (`GET /providers/proxies/{name}/healthcheck`). The endpoint returns
    /// 204 on success; fresh delays are surfaced on the next `getProviders()`.
    func healthCheckProvider(name: String) async throws {
        if Self.usesMockTransport { return }
        let url = credentials.baseURL.appending(path: "/providers/proxies/\(name.urlEscaped)/healthcheck")
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
        if Self.usesMockTransport, !usesInjectedWebSocketTransport {
            return Self.mockLogStream(level: level)
        }

        return AsyncThrowingStream { continuation in
            let log = self.log
            let task = Task {
                var backoff: UInt64 = 1
                while !Task.isCancelled {
                    // Recompute the target from the CURRENT credentials on
                    // every iteration — not once before the loop. A fresh
                    // install starts this loop against port 0 before the
                    // tunnel ever connects; `updateCredentials` retargets
                    // `credentials` once the engine mints real ones, and this
                    // snapshot is what makes the *next* retry pick that up
                    // instead of looping against 127.0.0.1:0 forever (#290).
                    let snapshot = credentials.snapshot
                    let url = snapshot.baseURL
                        .appending(path: "/logs")
                        .appending(queryItems: [.init(name: "level", value: level)])
                    var req = URLRequest(url: url)
                    if !snapshot.secret.isEmpty {
                        req.setValue("Bearer \(snapshot.secret)", forHTTPHeaderField: "Authorization")
                    }
                    #if DEBUG
                        log.info("WS upgrade \(url.absoluteString, privacy: .public)")
                    #endif
                    let ws = webSocketTaskFactory(req)
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

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var url = credentials.baseURL.appending(path: path)
        if !queryItems.isEmpty {
            url = url.appending(queryItems: queryItems)
        }
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
        let url = credentials.baseURL.appending(path: path)
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
        let url = credentials.baseURL.appending(path: path)
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
        let url = credentials.baseURL.appending(path: path)
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
        if !credentials.secret.isEmpty {
            req.setValue("Bearer \(credentials.secret)", forHTTPHeaderField: "Authorization")
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
