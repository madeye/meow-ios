import Charts
import MeowModels
import SwiftData
import SwiftUI

struct TrafficView: View {
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Query(sort: \DailyTraffic.date, order: .reverse) private var daily: [DailyTraffic]
    @State private var samples: [RateSample] = []
    private let window: TimeInterval = 60

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                chartsScrollView
            }
        }
        .navigationTitle("Traffic")
        .onChange(of: ipcBridge.currentTraffic) { _, snapshot in
            let sample = RateSample(
                timestamp: snapshot.timestamp,
                uploadRate: snapshot.uploadRate,
                downloadRate: snapshot.downloadRate,
            )
            samples.append(sample)
            let cutoff = Date().addingTimeInterval(-window)
            samples.removeAll { $0.timestamp < cutoff }
        }
    }

    private var isEmpty: Bool {
        daily.isEmpty && samples.isEmpty
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No traffic data yet",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("Start the VPN to begin recording usage."),
        )
        .accessibilityIdentifier("traffic.emptyState")
    }

    private var chartsScrollView: some View {
        ScrollView {
            VStack(spacing: 16) {
                speedCard
                HStack(spacing: 12) {
                    TotalsTile(
                        title: "Today",
                        tx: todayTotals.tx,
                        rx: todayTotals.rx,
                        identifier: "traffic.todayTile",
                    )
                    TotalsTile(
                        title: "This Month",
                        tx: monthTotals.tx,
                        rx: monthTotals.rx,
                        identifier: "traffic.monthTile",
                    )
                }
                historyCard
            }
            .padding()
        }
    }

    private var speedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speed")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Chart(samples) { sample in
                    LineMark(x: .value("t", sample.timestamp), y: .value("up", sample.uploadRate))
                        .foregroundStyle(by: .value("series", "Upload"))
                    LineMark(x: .value("t", sample.timestamp), y: .value("down", sample.downloadRate))
                        .foregroundStyle(by: .value("series", "Download"))
                }
                .frame(height: 180)
                .accessibilityIdentifier("traffic.speedChart")
            }
        }
    }

    private var historyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last 7 Days")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Chart(last7Days) { day in
                    BarMark(x: .value("day", day.date), y: .value("tx", day.txBytes))
                        .foregroundStyle(by: .value("series", "Upload"))
                    BarMark(x: .value("day", day.date), y: .value("rx", day.rxBytes))
                        .foregroundStyle(by: .value("series", "Download"))
                }
                .frame(height: 180)
                .accessibilityIdentifier("traffic.historyChart")
            }
        }
    }

    private struct RateSample: Identifiable {
        var id: Date {
            timestamp
        }

        let timestamp: Date
        let uploadRate: Int64
        let downloadRate: Int64
    }

    private var last7Days: [DailyTraffic] {
        Array(daily.prefix(7))
    }

    private var todayTotals: (tx: Int64, rx: Int64) {
        let key = DailyTraffic.key(for: .now)
        guard let entry = daily.first(where: { $0.date == key }) else { return (0, 0) }
        return (entry.txBytes, entry.rxBytes)
    }

    private var monthTotals: (tx: Int64, rx: Int64) {
        let prefix = DailyTraffic.key(for: .now).prefix(7) // yyyy-MM
        return daily
            .filter { $0.date.hasPrefix(prefix) }
            .reduce((Int64(0), Int64(0))) { ($0.0 + $1.txBytes, $0.1 + $1.rxBytes) }
    }
}

private struct TotalsTile: View {
    let title: String
    let tx: Int64
    let rx: Int64
    let identifier: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.smallCaps()).foregroundStyle(.secondary)
                Label(ByteCountFormatter.string(fromByteCount: tx, countStyle: .binary), systemImage: "arrow.up")
                    .accessibilityIdentifier("\(identifier).tx")
                Label(ByteCountFormatter.string(fromByteCount: rx, countStyle: .binary), systemImage: "arrow.down")
                    .accessibilityIdentifier("\(identifier).rx")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(identifier)
    }
}
