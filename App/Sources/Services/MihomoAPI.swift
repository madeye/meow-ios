import Foundation

/// REST client for the mihomo external-controller that runs inside the
/// packet-tunnel extension on `127.0.0.1:9090`. The URLSession requests are
/// issued from the main app process; iOS routes loopback traffic correctly
/// even when the tunnel is active.
@Observable
final class MihomoAPI: @unchecked Sendable {
    private let baseURL: URL
    private let secret: String
    private let session: URLSession

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

    func selectProxy(group: String, name: String) async throws {
        try await put("/proxies/\(group.urlEscaped)", body: ["name": name])
    }

    func testDelay(proxy: String, url: String, timeout: Int = 5000) async throws -> Int {
        struct Resp: Decodable { let delay: Int? }
        let endpoint = baseURL.appending(path: "/proxies/\(proxy.urlEscaped)/delay")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "url", value: url),
            .init(name: "timeout", value: String(timeout)),
        ]
        let (data, _) = try await session.data(for: request(for: comps.url!))
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
        let (_, resp) = try await session.data(for: request(for: url))
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
            let task = Task {
                let url = baseURL
                    .appending(path: "/logs")
                    .appending(queryItems: [.init(name: "level", value: level)])
                var req = URLRequest(url: url)
                if !secret.isEmpty {
                    req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                }
                let ws = session.webSocketTask(with: req)
                ws.resume()
                do {
                    while !Task.isCancelled {
                        let msg = try await ws.receive()
                        if case let .string(s) = msg,
                           let entry = LogEntry.from(jsonString: s)
                        {
                            continuation.yield(entry)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                ws.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, resp) = try await session.data(for: request(for: baseURL.appending(path: path)))
        try throwIfHTTPError(resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func put(_ path: String, body: [String: String]) async throws {
        var req = request(for: baseURL.appending(path: path))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: req)
        try throwIfHTTPError(resp)
    }

    private func delete(_ path: String) async throws {
        var req = request(for: baseURL.appending(path: path))
        req.httpMethod = "DELETE"
        let (_, resp) = try await session.data(for: req)
        try throwIfHTTPError(resp)
    }

    private func patchJSON(_ path: String, body: some Encodable) async throws {
        var req = request(for: baseURL.appending(path: path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (_, resp) = try await session.data(for: req)
        try throwIfHTTPError(resp)
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
}

private extension String {
    var urlEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
