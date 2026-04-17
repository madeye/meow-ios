import Foundation
import Observation
import MeowIPC
import MeowModels

/// App-side IPC: posts tunnel intents to the extension and observes the state
/// and traffic snapshots the extension writes to the shared container.
@MainActor
@Observable
final class AppIPCBridge {
    private(set) var currentState: VpnState = VpnState()
    private(set) var currentTraffic: TrafficSnapshot = TrafficSnapshot()

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
        }
    }
}
