import Darwin
import Foundation
import MeowModels
import Network
import os

/// In-process meow engine used to fetch GeoIP/ASN databases through the
/// user's first proxy without bringing `NEPacketTunnelProvider` up. Replaces
/// the bootstrap-tunnel detour formerly in `VpnManager.bootstrapGeoDownload`
/// — see `docs/adr/ADR-005-geoip-download-via-in-process-proxy.md`.
///
/// Lifecycle:
///   1. `start()` picks a random ephemeral mixed-port, writes a minimal YAML
///      to `AppGroup.bootstrapConfigDir/minimal.yaml`, calls
///      `meow_engine_start`, and probes the loopback listener for readiness.
///   2. Caller points `URLSession.connectionProxyDictionary` at
///      `127.0.0.1:<port>` and downloads.
///   3. `stop()` calls `meow_engine_stop`. The bootstrap engine is transient;
///      its port dies with the process and won't collide with the long-lived
///      PacketTunnel extension engine on 7890.
@MainActor
final class BootstrapEngine {
    enum Failure: LocalizedError {
        case engineStartFailed(String)
        case noPortAvailable
        case listenerNotReady

        var errorDescription: String? {
            switch self {
            case let .engineStartFailed(message):
                "Failed to start bootstrap engine: \(message)"
            case .noPortAvailable:
                "Bootstrap engine could not reserve a loopback port."
            case .listenerNotReady:
                "Bootstrap engine started but loopback listener never came up."
            }
        }
    }

    private nonisolated static let log = Logger(subsystem: "io.github.madeye.meow", category: "bootstrap-engine")

    private var runningPort: Int?

    var isRunning: Bool {
        runningPort != nil
    }

    /// Bring up the engine-only meow against a minimal config and return the
    /// loopback port URLSession should route through. Idempotent: returns the
    /// existing port if already started.
    func start() async throws -> Int {
        if let port = runningPort { return port }

        let sourceYAML = try String(contentsOf: AppGroup.configURL, encoding: .utf8)
        let port = try Self.reserveEphemeralPort()
        let minimalYAML = try MinimalConfigBuilder.build(sourceYAML: sourceYAML, mixedPort: port)

        try FileManager.default.createDirectory(
            at: AppGroup.bootstrapConfigDir,
            withIntermediateDirectories: true,
        )
        let configPath = AppGroup.bootstrapConfigDir.appending(path: "minimal.yaml")
        try minimalYAML.write(to: configPath, atomically: true, encoding: .utf8)

        let rc = configPath.path.withCString { meow_engine_start($0) }
        guard rc == 0 else {
            let msg = meow_core_last_error().map { String(cString: $0) } ?? "rc=\(rc)"
            throw Failure.engineStartFailed(msg)
        }

        try await waitForListener(port: port)
        runningPort = port
        Self.log.notice("bootstrap engine up on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    func stop() async {
        guard runningPort != nil else { return }
        meow_engine_stop()
        runningPort = nil
        Self.log.notice("bootstrap engine stopped")
    }

    // MARK: - Private

    /// Bind a transient socket on `127.0.0.1:0`, read back the OS-assigned
    /// port, then close it. Subject to a TOCTOU race against a concurrent
    /// binder, but the window is microseconds and the only realistic
    /// competitor (PacketTunnel extension engine) targets fixed 7890. If the
    /// kernel never honors our hand-off, `waitForListener` catches it.
    private static func reserveEphemeralPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.noPortAvailable }
        defer { close(fd) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw Failure.noPortAvailable }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        guard nameResult == 0 else { throw Failure.noPortAvailable }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    /// Same cold-connect readiness pattern as `AppModel.replaySelectedProxies`
    /// — 100 ms × up to 10 — but targeted at the loopback listener instead of
    /// the REST API. `meow_engine_start` returns before the mixed-port
    /// listener completes its bind, so a synchronous fall-through would lose
    /// the first URLSession connect.
    private func waitForListener(port: Int) async throws {
        for _ in 0 ..< 10 {
            if await Self.canConnect(toPort: port) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.listenerNotReady
    }

    private static func canConnect(toPort port: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp,
            )
            let resumer = ResultBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumer.takeOnce() {
                        continuation.resume(returning: true)
                    }
                    connection.cancel()
                case let .failed(error):
                    log.debug("listener probe failed: \(error.localizedDescription, privacy: .public)")
                    if resumer.takeOnce() {
                        continuation.resume(returning: false)
                    }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func takeOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
