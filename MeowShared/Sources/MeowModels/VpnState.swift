import Foundation

public enum VpnStage: String, Codable, Sendable, CaseIterable {
    case idle
    case connecting
    case connected
    case stopping
    case stopped
    case error
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
        startedAt: Date? = nil
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
    public var timestamp: Date

    public init(
        uploadBytes: Int64 = 0,
        downloadBytes: Int64 = 0,
        uploadRate: Int64 = 0,
        downloadRate: Int64 = 0,
        timestamp: Date = Date()
    ) {
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.uploadRate = uploadRate
        self.downloadRate = downloadRate
        self.timestamp = timestamp
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
