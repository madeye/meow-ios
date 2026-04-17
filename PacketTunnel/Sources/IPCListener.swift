import Foundation
import MeowIPC
import MeowModels

/// Extension-side receiver for app-originated intents. The app queues a
/// `TunnelIntent` in shared UserDefaults and posts `com.meow.vpn.command`;
/// the listener reads it and hands it off to the packet-tunnel provider.
final class IPCListener: Sendable {
    nonisolated(unsafe) private var observer: DarwinObserver?
    private let handler: @Sendable (TunnelIntent) -> Void

    init(handler: @escaping @Sendable (TunnelIntent) -> Void) {
        self.handler = handler
    }

    func start() {
        let handler = self.handler
        observer = DarwinBridge.addObserver(for: .command) {
            guard let intent = SharedStore.takeIntent() else { return }
            handler(intent)
        }
    }

    func stop() {
        observer.map { DarwinBridge.removeObserver($0) }
        observer = nil
    }
}
