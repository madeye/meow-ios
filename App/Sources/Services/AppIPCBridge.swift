import Foundation
import MeowIPC
import MeowModels
import Observation
import os

/// App-side IPC: posts tunnel intents to the extension and observes the state
/// and traffic snapshots the extension writes to the shared container.
@MainActor
@Observable
final class AppIPCBridge {
    private(set) var currentState: VpnState = .init()
    private(set) var currentTraffic: TrafficSnapshot = .init()

    private static let log = Logger(subsystem: "com.tangzixiang.meow", category: "ipc-bridge")

    private var stateObserver: DarwinObserver?
    private var trafficObserver: DarwinObserver?
    private var mockTrafficTask: Task<Void, Never>?

    func start() {
        if Self.usesMockIPC {
            startMockIPC()
            return
        }

        reloadState()
        reloadTraffic()
        stateObserver = DarwinBridge.addObserver(for: .state) { [weak self] in
            Task { @MainActor in self?.reloadState() }
        }
        trafficObserver = DarwinBridge.addObserver(for: .traffic) { [weak self] in
            Task { @MainActor in self?.reloadTraffic() }
        }
    }

    func stop() {
        mockTrafficTask?.cancel()
        mockTrafficTask = nil
        stateObserver.map { DarwinBridge.removeObserver($0) }
        trafficObserver.map { DarwinBridge.removeObserver($0) }
        stateObserver = nil
        trafficObserver = nil
    }

    /// Post an intent to the extension. The extension reads it on the next
    /// `com.meow.vpn.command` notification — this call queues the intent in
    /// shared UserDefaults first and posts the notification second so the
    /// receiver always sees the payload.
    func send(_ command: TunnelCommand, profileID: UUID? = nil) {
        if Self.usesMockIPC {
            sendMock(command, profileID: profileID)
            return
        }

        let intent = TunnelIntent(command: command, profileID: profileID?.uuidString)
        do {
            try SharedStore.queueIntent(intent)
            DarwinBridge.post(.command)
        } catch {
            // Queue failures are local-only (JSON encoding, disk write); log
            // via OSLog in a real build. The observable-state layer is the
            // user-visible surface, so we don't need to elevate here.
            Self.log.error("failed to queue intent: \(String(describing: error), privacy: .public)")
        }
    }

    private func reloadState() {
        if let state = SharedStore.readState() {
            currentState = state
        }
    }

    private func reloadTraffic() {
        if let traffic = SharedStore.readTraffic() {
            currentTraffic = traffic
            relayMemstats(traffic)
        }
    }

    /// Write memstats to the app's Documents folder so `xcrun devicectl device
    /// copy from --domain-type appDataContainer` can pull it from the Mac.
    private nonisolated func relayMemstats(_ t: TrafficSnapshot) {
        let line = "tick=\(t.pumpTick) footprint=\(t.footprintMB)MB " +
            "heap_used=\(t.heapUsedKB)KB heap_free=\(t.heapFreeKB)KB " +
            "tcp_conns=\(t.tcpConns) " +
            "up=\(t.uploadRate)B/s down=\(t.downloadRate)B/s " +
            "totalUp=\(t.uploadBytes)B totalDown=\(t.downloadBytes)B\n"
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appending(path: "memstats.txt")
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

private extension AppIPCBridge {
    nonisolated static var usesMockIPC: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    nonisolated static var shouldResetMockState: Bool {
        ProcessInfo.processInfo.arguments.contains("-ResetState")
    }

    func startMockIPC() {
        let persisted = Self.shouldResetMockState ? nil : SharedStore.readState()
        currentState = if let persisted, persisted.errorMessage == nil {
            persisted
        } else {
            .init(stage: .stopped)
        }
        try? SharedStore.writeState(currentState)

        currentTraffic = Self.shouldRunMockTraffic(for: currentState) ? Self.mockTraffic(tick: 0) : .init()
        relayMemstats(currentTraffic)

        configureMockTrafficTask()
    }

    func sendMock(_ command: TunnelCommand, profileID: UUID?) {
        switch command {
        case .start, .reload:
            currentState = .init(
                stage: .connected,
                profileID: profileID?.uuidString,
                profileName: nil,
                startedAt: Date(),
            )
        case .stop:
            currentState = .init(stage: .stopped)
        }
        try? SharedStore.writeState(currentState)
        currentTraffic = Self.shouldRunMockTraffic(for: currentState) ? Self.mockTraffic(tick: 0) : .init()
        relayMemstats(currentTraffic)
        configureMockTrafficTask()
    }

    func configureMockTrafficTask() {
        mockTrafficTask?.cancel()
        guard Self.shouldRunMockTraffic(for: currentState) else {
            mockTrafficTask = nil
            return
        }

        mockTrafficTask = Task { @MainActor [weak self] in
            var tick: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                guard let self else { return }
                currentTraffic = Self.mockTraffic(tick: tick)
                relayMemstats(currentTraffic)
            }
        }
    }

    nonisolated static func shouldRunMockTraffic(for state: VpnState) -> Bool {
        state.stage == .connected || screenshotTrafficRequested
    }

    nonisolated static var screenshotTrafficRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotTab"), i + 1 < args.count else { return false }
        return args[i + 1] == "traffic"
    }

    nonisolated static func mockTraffic(tick: Int64) -> TrafficSnapshot {
        TrafficSnapshot(
            uploadBytes: 486_539_264 + (tick * 94208),
            downloadBytes: 3_842_146_304 + (tick * 524_288),
            uploadRate: 42496 + ((tick % 5) * 8192),
            downloadRate: 384_000 + ((tick % 7) * 65536),
            ingressPackets: 18420 + (tick * 14),
            egressPackets: 12906 + (tick * 9),
            timestamp: Date(),
            footprintMB: 84,
            heapUsedKB: 19456,
            heapFreeKB: 8192,
            tcpConns: 24,
            pumpTick: tick,
        )
    }
}
