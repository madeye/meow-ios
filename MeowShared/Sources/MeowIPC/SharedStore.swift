import Foundation
import MeowModels

/// Reads and writes JSON-encoded state to the App Group container. Both the
/// app and the extension consume this — the sender writes atomically, the
/// reader treats a missing or malformed file as "no data yet."
public enum SharedStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func writeState(_ state: VpnState) throws {
        let data = try encoder.encode(state)
        try write(data, to: AppGroup.stateURL)
    }

    public static func readState() -> VpnState? {
        guard let data = try? Data(contentsOf: AppGroup.stateURL) else { return nil }
        return try? decoder.decode(VpnState.self, from: data)
    }

    public static func writeTraffic(_ traffic: TrafficSnapshot) throws {
        let data = try encoder.encode(traffic)
        try write(data, to: AppGroup.trafficURL)
    }

    public static func readTraffic() -> TrafficSnapshot? {
        guard let data = try? Data(contentsOf: AppGroup.trafficURL) else { return nil }
        return try? decoder.decode(TrafficSnapshot.self, from: data)
    }

    public static func queueIntent(_ intent: TunnelIntent) throws {
        let data = try encoder.encode(intent)
        AppGroup.defaults.set(data, forKey: PreferenceKey.pendingIntent)
    }

    public static func takeIntent() -> TunnelIntent? {
        guard let data = AppGroup.defaults.data(forKey: PreferenceKey.pendingIntent) else { return nil }
        AppGroup.defaults.removeObject(forKey: PreferenceKey.pendingIntent)
        return try? decoder.decode(TunnelIntent.self, from: data)
    }

    private static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
