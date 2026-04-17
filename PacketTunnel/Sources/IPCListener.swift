import Foundation
import MeowIPC
import MeowModels

/// Extension-side receiver for app-originated intents. The app queues a
/// `TunnelIntent` in shared UserDefaults and posts `com.meow.vpn.command`;
/// the listener reads it and hands it off to the packet-tunnel provider.
final class IPCListener {
    private var observer: DarwinObserver?
    private let handler: @Sendable (TunnelIntent) -> Void

    init(handler: @escaping @Sendable (TunnelIntent) -> Void) {
        self.handler = handler
    }

    func start() {
        observer = DarwinBridge.addObserver(for: .command) { [weak self] in
            guard let self, let intent = SharedStore.takeIntent() else { return }
            self.handler(intent)
        }
    }

    func stop() {
        observer.map { DarwinBridge.removeObserver($0) }
        observer = nil
    }
}
