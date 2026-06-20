import Foundation

public enum VpnStage: String, Codable, Sendable, CaseIterable {
    case idle
    /// App-side pre-flight before `startVPNTunnel`. Unused since the
    /// GeoIP/ASN download moved into the Rust engine — kept on the enum
    /// to preserve `Codable` compatibility with any persisted `VpnState`
    /// from older builds.
    case preparing
    case connecting
    case connected
    case stopping
    case stopped
    case error

    /// Whether a connection attempt is in flight or established — a live tunnel
    /// the app should treat as "on". Used to detect a stale App-Group snapshot
    /// that outlived its provider after an app replacement.
    public var isActive: Bool {
        self == .connecting || self == .connected
    }
}

public struct VpnState: Codable, Sendable, Equatable {
    public var stage: VpnStage
    public var profileID: String?
    public var profileName: String?
    public var errorMessage: String?
    public var startedAt: Date?

    public init(
        stage: VpnStage = .idle,
        profileID: String? = nil,
        profileName: String? = nil,
        errorMessage: String? = nil,
        startedAt: Date? = nil,
    ) {
        self.stage = stage
        self.profileID = profileID
        self.profileName = profileName
        self.errorMessage = errorMessage
        self.startedAt = startedAt
    }
}

public struct TrafficSnapshot: Codable, Sendable, Equatable {
    public var uploadBytes: Int64
    public var downloadBytes: Int64
    public var uploadRate: Int64
    public var downloadRate: Int64
    public var ingressPackets: Int64
    public var egressPackets: Int64
    public var timestamp: Date
    public var footprintMB: Int64
    public var heapUsedKB: Int64
    public var heapFreeKB: Int64
    public var tcpConns: Int64
    public var pumpTick: Int64

    public init(
        uploadBytes: Int64 = 0,
        downloadBytes: Int64 = 0,
        uploadRate: Int64 = 0,
        downloadRate: Int64 = 0,
        ingressPackets: Int64 = 0,
        egressPackets: Int64 = 0,
        timestamp: Date = Date(),
        footprintMB: Int64 = 0,
        heapUsedKB: Int64 = 0,
        heapFreeKB: Int64 = 0,
        tcpConns: Int64 = 0,
        pumpTick: Int64 = 0,
    ) {
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.uploadRate = uploadRate
        self.downloadRate = downloadRate
        self.ingressPackets = ingressPackets
        self.egressPackets = egressPackets
        self.timestamp = timestamp
        self.footprintMB = footprintMB
        self.heapUsedKB = heapUsedKB
        self.heapFreeKB = heapFreeKB
        self.tcpConns = tcpConns
        self.pumpTick = pumpTick
    }
}

public enum TunnelCommand: String, Codable, Sendable {
    case start
    case stop
    case reload
}

public struct TunnelIntent: Codable, Sendable {
    public var command: TunnelCommand
    public var profileID: String?

    public init(command: TunnelCommand, profileID: String? = nil) {
        self.command = command
        self.profileID = profileID
    }
}
