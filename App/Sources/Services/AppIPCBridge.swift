import Foundation
import MeowIPC
import MeowModels
import Observation

/// App-side IPC: posts tunnel intents to the extension and observes the state
/// and traffic snapshots the extension writes to the shared container.
@MainActor
@Observable
final class AppIPCBridge {
    private(set) var currentState: VpnState = .init()
    private(set) var currentTraffic: TrafficSnapshot = .init()

    private var stateObserver: DarwinObserver?
    private var trafficObserver: DarwinObserver?

    func start() {
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
        let intent = TunnelIntent(command: command, profileID: profileID?.uuidString)
        do {
            try SharedStore.queueIntent(intent)
            DarwinBridge.post(.command)
        } catch {
            // Queue failures are local-only (JSON encoding, disk write); log
            // via OSLog in a real build. The observable-state layer is the
            // user-visible surface, so we don't need to elevate here.
            NSLog("IPCBridge: failed to queue intent: %@", String(describing: error))
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
