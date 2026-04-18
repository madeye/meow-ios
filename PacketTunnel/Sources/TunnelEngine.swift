import Foundation
import MeowIPC
import MeowModels
import NetworkExtension
import os.log

/// Orchestrates the mihomo-rust engine and the tun2socks layer inside the
/// packet-tunnel extension. Both halves live in the same static library
/// (`MihomoCore.xcframework`) and dispatch in-process — no SOCKS5 loopback,
/// no socketpair. `PacketWriter` + `meowPacketWriteCallback` form the egress
/// bridge; this class drives ingress via `NEPacketTunnelFlow.readPackets` and
/// forwards each packet into `meow_tun_ingest`.
///
/// `@unchecked Sendable`: NEPacketTunnelProvider serializes startTunnel/stopTunnel
/// for us (see NetworkExtension.framework docs), so this class is only touched
/// from one call chain at a time. Do not "helpfully" add actor isolation.
final class TunnelEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "io.github.madeye.meow.PacketTunnel", category: "engine")
    private let packetFlow: NEPacketTunnelFlow
    private var ingressTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var writerRef: Unmanaged<PacketWriter>?
    private var started = false
    private(set) var tunStarted = false
    private let ingressPackets = ManagedAtomicCounter()

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func start() async throws {
        guard !started else { return }
        started = true

        let homeDir = AppGroup.containerURL.path
        let prefs = Preferences.load(from: AppGroup.defaults)

        try writeEffectiveConfig(prefs: prefs)

        meow_core_init()
        homeDir.withCString { meow_core_set_home_dir($0) }

        let configPath = AppGroup.effectiveConfigURL.path
        let engineStarted = configPath.withCString { meow_engine_start($0) }
        if engineStarted != 0 {
            started = false
            throw TunnelEngineError.engineStartFailed(lastRustError())
        }

        let writer = PacketWriter(flow: packetFlow)
        let ref = Unmanaged.passRetained(writer)
        writerRef = ref
        if meow_tun_start(ref.toOpaque(), meowPacketWriteCallback) != 0 {
            ref.release()
            writerRef = nil
            meow_engine_stop()
            started = false
            throw TunnelEngineError.tunStartFailed(lastRustError())
        }
        tunStarted = true

        let ingressCounter = ingressPackets
        ingressTask = Task.detached { [packetFlow] in
            await TunnelEngine.runIngressLoop(flow: packetFlow, counter: ingressCounter)
        }
        trafficTask = Task { await self.trafficPump() }
    }

    func stop() async {
        guard started else { return }
        started = false
        ingressTask?.cancel()
        trafficTask?.cancel()

        meow_tun_stop()
        tunStarted = false
        meow_engine_stop()

        writerRef?.release()
        writerRef = nil
    }

    func runDiagnostics() -> DiagnosticsReport {
        DiagnosticsRunner.run(
            engineRunning: isEngineRunning,
            tunStarted: tunStarted,
        )
    }

    func reloadConfig() async throws {
        let prefs = Preferences.load(from: AppGroup.defaults)
        try writeEffectiveConfig(prefs: prefs)
        // Hot-reload is a POST /configs on mihomo-rust's REST API; wiring the
        // extension ↔ API call lands with the reload flow in M3. For now a
        // full stop/start is the safe path.
    }

    var isEngineRunning: Bool {
        meow_engine_is_running() != 0
    }

    // MARK: - Ingress

    private static func runIngressLoop(flow: NEPacketTunnelFlow, counter: ManagedAtomicCounter) async {
        // DIAGNOSTIC: remove once tunnel ingest is verified stable in v1.0.
        let log = Logger(subsystem: "io.github.madeye.meow.PacketTunnel", category: "engine")
        while !Task.isCancelled {
            let packets = await withCheckedContinuation { (cont: CheckedContinuation<[Data], Never>) in
                flow.readPackets { packets, _ in
                    cont.resume(returning: packets)
                }
            }
            log.info("ingress batch: count=\(packets.count, privacy: .public)")
            for packet in packets {
                packet.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    _ = meow_tun_ingest(base, UInt(buf.count))
                }
                counter.increment()
            }
        }
    }

    // MARK: - Private

    private func writeEffectiveConfig(prefs: Preferences) throws {
        let source = try String(contentsOf: AppGroup.configURL, encoding: .utf8)
        try EffectiveConfigWriter.write(
            sourceYAML: source,
            to: AppGroup.effectiveConfigURL,
            prefs: prefs,
        )
    }

    private func trafficPump() async {
        var lastUp: Int64 = 0
        var lastDown: Int64 = 0
        var lastTime = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            var up: Int64 = 0
            var down: Int64 = 0
            meow_engine_traffic(&up, &down)
            let now = Date()
            let dt = max(0.001, now.timeIntervalSince(lastTime))
            let snapshot = TrafficSnapshot(
                uploadBytes: up,
                downloadBytes: down,
                uploadRate: Int64(Double(up - lastUp) / dt),
                downloadRate: Int64(Double(down - lastDown) / dt),
                ingressPackets: ingressPackets.load(),
                egressPackets: writerRef?.takeUnretainedValue().egressPackets.load() ?? 0,
                timestamp: now,
            )
            lastUp = up; lastDown = down; lastTime = now
            do {
                try SharedStore.writeTraffic(snapshot)
                DarwinBridge.post(.traffic)
            } catch {
                log.error("traffic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func lastRustError() -> String {
        if let cstr = meow_core_last_error() { return String(cString: cstr) }
        return ""
    }
}

enum TunnelEngineError: LocalizedError {
    case engineStartFailed(String)
    case tunStartFailed(String)

    var errorDescription: String? {
        switch self {
        case let .engineStartFailed(detail):
            "engine start failed" + (detail.isEmpty ? "" : ": \(detail)")
        case let .tunStartFailed(detail):
            "tun start failed" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}
