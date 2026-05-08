import Foundation
import MeowIPC
import NetworkExtension
import os

/// REST client for the mihomo external-controller that runs inside the
/// packet-tunnel extension on `127.0.0.1:9090`. The URLSession requests are
/// issued from the main app process; iOS routes loopback traffic correctly
/// even when the tunnel is active.
@Observable
final class MihomoAPI: @unchecked Sendable {
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
    // Mirrors the ingress-instrumentation pattern kept around #54.
    private let log = Logger(subsystem: "io.github.madeye.meow.app", category: "mihomo-api")

    init(
        port: Int = 9090,
        secret: String = "",
        session: URLSession = .shared,
    ) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        self.session = session
    }

    // MARK: - Endpoints

    func getProxies() async throws -> ProxiesResponse {
        try await get("/proxies")
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
    /// a clearer error). Set `MihomoIPCDisabled = YES` in UserDefaults
    /// to force the HTTP path for debugging.
    func selectProxy(group: String, name: String) async throws {
        let ipcDisabled = UserDefaults.standard.bool(forKey: "MihomoIPCDisabled")
        if !ipcDisabled, let session = await Self.tunnelSession() {
            try await selectProxyViaIPC(session: session, group: group, name: name)
            return
        }
        try await put("/proxies/\(group.urlEscaped)", body: ["name": name])
    }

    /// Single-shot request/response over `NETunnelProviderSession`.
    /// Errors here surface as `MihomoAPIError.proxyControl` so the UI can
    /// distinguish "engine not running" / "name not in selector" from a
    /// transport failure.
    private func selectProxyViaIPC(
        session: NETunnelProviderSession,
        group: String,
        name: String,
    ) async throws {
        let payload = try ProxyControlIPC.encodeRequest(.select(group: group, name: name))
        log.info("IPC proxy_select group=\(group, privacy: .public) name=\(name, privacy: .public)")
        let response: ProxyControlResponse = try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    guard let data else {
                        cont.resume(throwing: MihomoAPIError.proxyControl(reason: "no response from extension"))
                        return
                    }
                    do {
                        let decoded = try ProxyControlIPC.decodeResponse(data)
                        cont.resume(returning: decoded)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
        guard response.success else {
            throw MihomoAPIError.proxyControl(reason: response.errorReason ?? "unknown (code \(response.code ?? -99))")
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
        struct Resp: Decodable { let delay: Int? }
        let endpoint = baseURL.appending(path: "/proxies/\(proxy.urlEscaped)/delay")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "url", value: url),
            .init(name: "timeout", value: String(timeout)),
        ]
        let target = comps.url!
        // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
        log.info("HTTP GET \(target.absoluteString, privacy: .public)")
        let (data, resp) = try await session.data(for: request(for: target))
        logResponse(resp, body: data, url: target)
        return try (JSONDecoder().decode(Resp.self, from: data).delay) ?? -1
    }

    func getConnections() async throws -> ConnectionsResponse {
        try await get("/connections")
    }

    func closeConnection(id: String) async throws {
        try await delete("/connections/\(id)")
    }

    func closeAllConnections() async throws {
        try await delete("/connections")
    }

    func getRules() async throws -> RulesResponse {
        try await get("/rules")
    }

    func getProviders() async throws -> ProvidersResponse {
        try await get("/providers/proxies")
    }

    /// Triggers mihomo's bulk health-check for every proxy in a provider
    /// (`GET /providers/proxies/{name}/healthcheck`). The endpoint returns
    /// 204 on success; fresh delays are surfaced on the next `getProviders()`.
    func healthCheckProvider(name: String) async throws {
        let url = baseURL.appending(path: "/providers/proxies/\(name.urlEscaped)/healthcheck")
        // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
        log.info("HTTP GET \(url.absoluteString, privacy: .public)")
        let (data, resp) = try await session.data(for: request(for: url))
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    func getMemory() async throws -> MemoryResponse {
        try await get("/memory")
    }

    func getConfigs() async throws -> ConfigsResponse {
        try await get("/configs")
    }

    func patchConfigs(_ patch: ConfigsPatch) async throws {
        try await patchJSON("/configs", body: patch)
    }

    /// Stream mihomo logs via WebSocket. Caller owns the AsyncStream — it
    /// stops when the task is cancelled.
    func streamLogs(level: String = "info") -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let log = self.log
            let task = Task {
                let url = baseURL
                    .appending(path: "/logs")
                    .appending(queryItems: [.init(name: "level", value: level)])
                var req = URLRequest(url: url)
                if !secret.isEmpty {
                    req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                }
                // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
                log.info("WS upgrade \(url.absoluteString, privacy: .public)")
                let ws = session.webSocketTask(with: req)
                ws.resume()
                do {
                    while !Task.isCancelled {
                        let msg = try await ws.receive()
                        if case let .string(s) = msg {
                            // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
                            log.info("WS frame /logs: \(s.prefix(200), privacy: .public)")
                            if let entry = LogEntry.from(jsonString: s) {
                                continuation.yield(entry)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
                    log.error("WS /logs error: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
                ws.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appending(path: path)
        // DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
        log.info("HTTP GET \(url.absoluteString, privacy: .public)")
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
        log.info("HTTP PUT \(url.absoluteString, privacy: .public)")
        let (data, resp) = try await session.data(for: req)
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    private func delete(_ path: String) async throws {
        let url = baseURL.appending(path: path)
        var req = request(for: url)
        req.httpMethod = "DELETE"
        log.info("HTTP DELETE \(url.absoluteString, privacy: .public)")
        let (data, resp) = try await session.data(for: req)
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    private func patchJSON(_ path: String, body: some Encodable) async throws {
        let url = baseURL.appending(path: path)
        var req = request(for: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        log.info("HTTP PATCH \(url.absoluteString, privacy: .public)")
        let (data, resp) = try await session.data(for: req)
        logResponse(resp, body: data, url: url)
        try throwIfHTTPError(resp)
    }

    /// DIAGNOSTIC: remove once Logs/Connections views are stable in v1.0.
    private func logResponse(_ response: URLResponse, body: Data, url: URL) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let preview = String(data: body.prefix(200), encoding: .utf8) ?? "<non-utf8 \(body.count) bytes>"
        log.info("HTTP \(status, privacy: .public) from \(url.path, privacy: .public): \(preview, privacy: .public)")
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
            throw MihomoAPIError.http(status: http.statusCode)
        }
    }
}

enum MihomoAPIError: Error {
    case http(status: Int)
    case malformed
    case proxyControl(reason: String)
}

private extension String {
    var urlEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
