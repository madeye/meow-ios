import Foundation
@testable import meow_ios

/// Thread-safe capture of every `URLRequest` a `MeowWebSocketTransport`
/// factory was invoked with, in call order. `streamLogs`'s reconnect loop
/// runs on a detached `Task`, so recording has to be safe to call
/// concurrently with the assertions made from the test's task.
final class WebSocketRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(at index: Int) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard requests.indices.contains(index) else { return nil }
        return requests[index]
    }
}

/// `MeowWebSocketTransport` that fails every `receive()` immediately, so
/// `streamLogs`'s retry loop cycles through reconnect attempts (recorded by
/// `WebSocketRequestRecorder`) without ever opening a real socket.
final class ImmediatelyFailingWebSocketTransport: MeowWebSocketTransport {
    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw URLError(.networkConnectionLost)
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {}
}
