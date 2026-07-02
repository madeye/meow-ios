import Foundation
import MeowModels
import Observation

/// Rolling 60s upload/download rate samples for the Traffic utility screen.
/// Hoisted out of `TrafficView` so the chart survives Utility hub back-navigation.
@MainActor
@Observable
final class UtilityTrafficChartStore {
    private(set) var samples: [TrafficRateSample] = []
    private let window: TimeInterval = 60

    func ingest(_ snapshot: TrafficSnapshot) {
        let sample = TrafficRateSample(
            timestamp: snapshot.timestamp,
            uploadRate: snapshot.uploadRate,
            downloadRate: snapshot.downloadRate,
        )
        samples.append(sample)
        let cutoff = Date().addingTimeInterval(-window)
        samples.removeAll { $0.timestamp < cutoff }
    }
}

struct TrafficRateSample: Identifiable {
    var id: Date {
        timestamp
    }

    let timestamp: Date
    let uploadRate: Int64
    let downloadRate: Int64
}

/// Log ring buffer and live WebSocket subscription for the Logs utility screen.
/// Hoisted so entries survive Utility hub back-navigation.
@MainActor
@Observable
final class UtilityLogsStore {
    private(set) var allEntries: [LogEntry] = []
    var errorMessage: String?

    private var streamTask: Task<Void, Never>?

    func startStreaming(api: MeowAPI) {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = api.streamLogs(level: "debug")
            do {
                for try await entry in stream {
                    guard let self else { return }
                    errorMessage = nil
                    allEntries.append(entry)
                    if allEntries.count > 2000 {
                        allEntries.removeFirst(allEntries.count - 2000)
                    }
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}
