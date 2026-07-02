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
        // The IPC bridge calls this on every store refresh, not only on value
        // changes (unlike the old `.onChange` in TrafficView) — skip repeats
        // so chart sample IDs (timestamps) stay unique.
        guard samples.last?.timestamp != snapshot.timestamp else { return }
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
    var level = "info"
    var autoScroll = true

    private var streamTask: Task<Void, Never>?

    func startStreaming(api: MeowAPI) {
        guard streamTask == nil else { return }
        streamTask = Task { @MainActor [weak self] in
            // Reconnect loop: the first attempt usually races VPN start (the
            // NE REST API is only up while the tunnel runs), and the stream
            // ends whenever the tunnel restarts. Keep retrying so Logs heals
            // without an app relaunch.
            while !Task.isCancelled {
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
                    guard let self else { return }
                    errorMessage = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
