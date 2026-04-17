import Foundation
import NetworkExtension
import os.log
import MeowIPC
import MeowModels

/// Orchestrates the mihomo-rust engine and the tun2socks layer inside the
/// packet-tunnel extension. Both halves live in the same static library
/// (`MihomoCore.xcframework`) and dispatch in-process — no SOCKS5 loopback.
/// The Rust side needs a file descriptor it can read from, and
/// `NEPacketTunnelFlow` doesn't expose one, so `TunnelEngine` creates a
/// socketpair and pumps packets between `packetFlow` and the Rust fd.
final class TunnelEngine {
    private let log = Logger(subsystem: "io.github.madeye.meow.PacketTunnel", category: "engine")
    private let packetFlow: NEPacketTunnelFlow
    private var pumpTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var swiftSideFd: Int32 = -1
    private var rustSideFd: Int32 = -1
    private var started = false

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func start() async throws {
        guard !started else { return }
        started = true

        let homeDir = AppGroup.containerURL.path
        let prefs = Preferences.load(from: AppGroup.defaults)

        try writeEffectiveConfig(prefs: prefs)

        #if MIHOMO_CORE_LINKED
        meow_core_init()
        homeDir.withCString { meow_core_set_home_dir($0) }

        let configPath = AppGroup.configURL.path
        let engineStarted = configPath.withCString { meow_engine_start($0) }
        if engineStarted != 0 {
            throw TunnelEngineError.engineStartFailed(lastRustError())
        }

        try openSocketPair()
        if meow_tun_start(rustSideFd, Int32(prefs.mixedPort), Int32(prefs.localDnsPort)) != 0 {
            throw TunnelEngineError.tunStartFailed(lastRustError())
        }
        pumpTask = Task.detached { [swiftSideFd, packetFlow] in
            await PacketPump.run(fd: swiftSideFd, packetFlow: packetFlow)
        }
        #else
        log.info("Rust engine placeholder — MIHOMO_CORE_LINKED not defined; skipping start")
        #endif

        trafficTask = Task { await self.trafficPump() }
    }

    func stop() async {
        guard started else { return }
        started = false
        pumpTask?.cancel()
        trafficTask?.cancel()

        #if MIHOMO_CORE_LINKED
        meow_tun_stop()
        meow_engine_stop()
        #endif
        closeSocketPair()
    }

    func reloadConfig() async throws {
        let prefs = Preferences.load(from: AppGroup.defaults)
        try writeEffectiveConfig(prefs: prefs)
        // Hot-reload is a POST /configs on mihomo-rust's REST API; wiring the
        // extension ↔ API call lands with the reload flow in M3. For now a
        // full stop/start is the safe path.
        _ = prefs
    }

    var isEngineRunning: Bool {
        #if MIHOMO_CORE_LINKED
        return meow_engine_is_running() != 0
        #else
        return false
        #endif
    }

    // MARK: - Private

    private func writeEffectiveConfig(prefs: Preferences) throws {
        _ = prefs
        _ = AppGroup.configURL
    }

    private func openSocketPair() throws {
        var fds = [Int32](repeating: 0, count: 2)
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_DGRAM, 0, buf.baseAddress)
        }
        if rc != 0 {
            throw TunnelEngineError.socketPairFailed(errno)
        }
        swiftSideFd = fds[0]
        rustSideFd = fds[1]
    }

    private func closeSocketPair() {
        if swiftSideFd >= 0 { close(swiftSideFd); swiftSideFd = -1 }
        if rustSideFd >= 0 { close(rustSideFd); rustSideFd = -1 }
    }

    private func trafficPump() async {
        var lastUp: Int64 = 0
        var lastDown: Int64 = 0
        var lastTime = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            var up: Int64 = 0
            var down: Int64 = 0
            #if MIHOMO_CORE_LINKED
            meow_engine_traffic(&up, &down)
            #endif
            let now = Date()
            let dt = max(0.001, now.timeIntervalSince(lastTime))
            let snapshot = TrafficSnapshot(
                uploadBytes: up,
                downloadBytes: down,
                uploadRate: Int64(Double(up - lastUp) / dt),
                downloadRate: Int64(Double(down - lastDown) / dt),
                timestamp: now
            )
            lastUp = up; lastDown = down; lastTime = now
            do {
                try SharedStore.writeTraffic(snapshot)
                DarwinBridge.post(.traffic)
            } catch {
                log.error("traffic write failed: \(error.localizedDescription)")
            }
        }
    }

    private func lastRustError() -> String {
        #if MIHOMO_CORE_LINKED
        if let cstr = meow_core_last_error() { return String(cString: cstr) }
        #endif
        return ""
    }
}

enum TunnelEngineError: Error {
    case engineStartFailed(String)
    case tunStartFailed(String)
    case socketPairFailed(Int32)
}
