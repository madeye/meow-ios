import Foundation

/// Named Darwin notifications (CFNotificationCenter) used as the IPC channel
/// between the main app and the packet-tunnel extension. Both processes can
/// post and observe them; the payload itself lives in the shared App Group
/// container (UserDefaults for commands, JSON files for state/traffic).
public enum MeowNotification: String, Sendable {
    case command = "com.meow.vpn.command"
    case state = "com.meow.vpn.state"
    case traffic = "com.meow.vpn.traffic"

    public var cfName: CFNotificationName {
        CFNotificationName(rawValue as CFString)
    }
}

public enum DarwinBridge {
    /// Post a Darwin notification with no payload. Receivers must read the
    /// shared container (or UserDefaults) to obtain the associated data.
    public static func post(_ notification: MeowNotification) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            notification.cfName,
            nil,
            nil,
            true,
        )
    }

    /// Observe a Darwin notification. The closure is invoked on the main
    /// thread. Returns an opaque token — retain it until you no longer want
    /// notifications, then pass it to ``removeObserver(_:)``.
    @discardableResult
    public static func addObserver(
        for notification: MeowNotification,
        handler: @escaping @Sendable () -> Void,
    ) -> DarwinObserver {
        let observer = DarwinObserver(notification: notification, handler: handler)
        observer.start()
        return observer
    }

    public static func removeObserver(_ observer: DarwinObserver) {
        observer.stop()
    }
}

public final class DarwinObserver: @unchecked Sendable {
    private let notification: MeowNotification
    private let handler: @Sendable () -> Void
    private var token: UnsafeMutableRawPointer?

    init(notification: MeowNotification, handler: @escaping @Sendable () -> Void) {
        self.notification = notification
        self.handler = handler
    }

    func start() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        token = unmanaged
        CFNotificationCenterAddObserver(
            center,
            unmanaged,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let this = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                this.handler()
            },
            notification.rawValue as CFString,
            nil,
            .deliverImmediately,
        )
    }

    func stop() {
        guard let token else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(center, token, notification.cfName, nil)
        self.token = nil
    }

    deinit { stop() }
}
