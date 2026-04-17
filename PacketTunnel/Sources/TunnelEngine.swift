import Foundation
import NetworkExtension
import os.log
import MeowIPC
import MeowModels

/// Orchestrates the Go mihomo engine and the Rust tun2socks layer inside the
/// packet-tunnel extension. The Rust side needs a file descriptor it can read
/// from; NEPacketTunnelFlow doesn't expose one, so TunnelEngine establishes a
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

        // Initialize Go mihomo and start it bound to loopback.
        #if MIHOMO_GO_LINKED
        homeDir.withCString { meowSetHomeDir($0) }
        meowEngineInit()
        let controller = "127.0.0.1:9090"
        let secret = AppGroup.defaults.string(forKey: PreferenceKey.apiSecret) ?? ""
        let result = controller.withCString { addr in
            secret.withCString { sec in meowStartEngine(addr, sec) }
        }
        if result != 0 {
            throw TunnelEngineError.engineStartFailed(lastGoError())
        }
        #else
        log.info("Go engine placeholder — MIHOMO_GO_LINKED not defined; skipping startEngine")
        #endif

        // Initialize Rust tun2socks.
        #if MIHOMO_FFI_LINKED
        meow_tun_init()
        homeDir.withCString { meow_tun_set_home_dir($0) }
        try openSocketPair()
        if meow_tun_start(rustSideFd, Int32(prefs.mixedPort), Int32(prefs.localDnsPort)) != 0 {
            throw TunnelEngineError.tunStartFailed(lastRustError())
        }
        pumpTask = Task.detached { [swiftSideFd, packetFlow] in
            await PacketPump.run(fd: swiftSideFd, packetFlow: packetFlow)
        }
        #else
        log.info("Rust tun2socks placeholder — MIHOMO_FFI_LINKED not defined; skipping tun start")
        #endif

        trafficTask = Task { await self.trafficPump() }
    }

    func stop() async {
        guard started else { return }
        started = false
        pumpTask?.cancel()
        trafficTask?.cancel()

        #if MIHOMO_FFI_LINKED
        meow_tun_stop()
        #endif
        #if MIHOMO_GO_LINKED
        meowStopEngine()
        #endif
        closeSocketPair()
    }

    func reloadConfig() async throws {
        let prefs = Preferences.load(from: AppGroup.defaults)
        try writeEffectiveConfig(prefs: prefs)
        #if MIHOMO_GO_LINKED
        // mihomo re-reads on next Parse; a full reload flow will be added in M3.
        _ = prefs
        #endif
    }

    // MARK: - Private

    private func writeEffectiveConfig(prefs: Preferences) throws {
        // The app writes the raw profile YAML to config.yaml on select. Here
        // we patch in the fixed mixed-port / external-controller the
        // extension relies on. For now this is a no-op placeholder — the
        // logic will be fleshed out in M1 once the Go binding exists.
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
            #if MIHOMO_GO_LINKED
            let up = Int64(meowGetUploadTraffic())
            let down = Int64(meowGetDownloadTraffic())
            #else
            let up: Int64 = 0
            let down: Int64 = 0
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

    private func lastGoError() -> String {
        #if MIHOMO_GO_LINKED
        var buf = [CChar](repeating: 0, count: 512)
        _ = meowGetLastError(&buf, Int32(buf.count))
        return String(cString: buf)
        #else
        return ""
        #endif
    }

    private func lastRustError() -> String {
        #if MIHOMO_FFI_LINKED
        if let cstr = meow_tun_last_error() { return String(cString: cstr) }
        #endif
        return ""
    }
}

enum TunnelEngineError: Error {
    case engineStartFailed(String)
    case tunStartFailed(String)
    case socketPairFailed(Int32)
}
