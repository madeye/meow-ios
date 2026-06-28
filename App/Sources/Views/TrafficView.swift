import Accessibility
import Charts
import MeowModels
import SwiftData
import SwiftUI

struct TrafficView: View {
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
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
        .navigationTitle("traffic.nav.title")
        .navigationBarTitleDisplayMode(.inline)
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
            "traffic.empty.title",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("traffic.empty.description"),
        )
        .accessibilityIdentifier("traffic.emptyState")
    }

    private var chartsScrollView: some View {
        ScrollView {
            VStack(spacing: 16) {
                speedCard
                HStack(spacing: 12) {
                    TotalsTile(
                        title: "traffic.tile.today",
                        tx: todayTotals.tx,
                        rx: todayTotals.rx,
                        identifier: "traffic.todayTile",
                    )
                    TotalsTile(
                        title: "traffic.tile.thisMonth",
                        tx: monthTotals.tx,
                        rx: monthTotals.rx,
                        identifier: "traffic.monthTile",
                    )
                }
                historyCard
            }
            .padding()
        }
        .background(AppTheme.screenBackground)
    }

    private var speedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("traffic.label.speed")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Chart(samples) { sample in
                    LineMark(x: .value("t", sample.timestamp), y: .value("up", sample.uploadRate))
                        .foregroundStyle(by: .value("series", "Upload"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: differentiateWithoutColor ? [4, 3] : []))
                    LineMark(x: .value("t", sample.timestamp), y: .value("down", sample.downloadRate))
                        .foregroundStyle(by: .value("series", "Download"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale([
                    "Upload": AppTheme.warning,
                    "Download": AppTheme.accent,
                ])
                .frame(height: 180)
                .accessibilityIdentifier("traffic.speedChart")
                .accessibilityLabel(Text("traffic.label.speed"))
                .accessibilityValue(speedChartValue)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityChartDescriptor(SpeedChartDescriptor(samples: samples))
            }
        }
    }

    private var historyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("traffic.label.last7Days")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Chart(last7Days) { day in
                    BarMark(x: .value("day", day.date), y: .value("tx", day.txBytes))
                        .foregroundStyle(by: .value("series", "Upload"))
                    BarMark(x: .value("day", day.date), y: .value("rx", day.rxBytes))
                        .foregroundStyle(by: .value("series", "Download"))
                }
                .chartForegroundStyleScale([
                    "Upload": AppTheme.warning,
                    "Download": AppTheme.accent,
                ])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(Self.gigabyteFormatter.string(fromByteCount: Int64(bytes)))
                            }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityIdentifier("traffic.historyChart")
                .accessibilityLabel(Text("traffic.label.last7Days"))
                .accessibilityValue(historyChartValue)
                .accessibilityChartDescriptor(HistoryChartDescriptor(days: last7Days))
            }
        }
    }

    private var speedChartValue: Text {
        let up = ByteCountFormatter.string(fromByteCount: samples.last?.uploadRate ?? 0, countStyle: .binary)
        let down = ByteCountFormatter.string(fromByteCount: samples.last?.downloadRate ?? 0, countStyle: .binary)
        return Text("a11y.traffic.speedChart.value \(up) \(down)")
    }

    private var historyChartValue: Text {
        let totals = last7Days.reduce((Int64(0), Int64(0))) { ($0.0 + $1.txBytes, $0.1 + $1.rxBytes) }
        let up = ByteCountFormatter.string(fromByteCount: totals.0, countStyle: .binary)
        let down = ByteCountFormatter.string(fromByteCount: totals.1, countStyle: .binary)
        return Text("a11y.traffic.historyChart.value \(up) \(down)")
    }

    /// Forces GB units on the 7-day chart Y-axis. Daily totals run into the
    /// gigabyte range fast, and ByteCountFormatter's auto mode flips between
    /// MB / GB across ticks, which makes the bar heights hard to compare.
    private static let gigabyteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useGB
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f
    }()

    private struct RateSample: Identifiable {
        var id: Date {
            timestamp
        }

        let timestamp: Date
        let uploadRate: Int64
        let downloadRate: Int64
    }

    /// Audio Graph descriptor for the live speed chart, so VoiceOver users can
    /// sonically explore the upload/download curves.
    private struct SpeedChartDescriptor: AXChartDescriptorRepresentable {
        let samples: [RateSample]

        func makeChartDescriptor() -> AXChartDescriptor {
            let start = samples.first?.timestamp ?? .now
            let end = samples.last?.timestamp ?? .now
            let xAxis = AXNumericDataAxisDescriptor(
                title: String(localized: "a11y.traffic.chart.axis.time"),
                range: 0 ... max(end.timeIntervalSince(start), 1),
                gridlinePositions: [],
            ) { value in
                String(localized: "a11y.traffic.chart.seconds \(String(Int(value)))")
            }
            let maxRate = samples.map { max($0.uploadRate, $0.downloadRate) }.max() ?? 0
            let yAxis = AXNumericDataAxisDescriptor(
                title: String(localized: "a11y.traffic.chart.axis.speed"),
                range: 0 ... Double(max(maxRate, 1)),
                gridlinePositions: [],
            ) { value in
                ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
            }
            let upload = AXDataSeriesDescriptor(
                name: String(localized: "home.traffic.upload"),
                isContinuous: true,
                dataPoints: samples.map {
                    AXDataPoint(x: $0.timestamp.timeIntervalSince(start), y: Double($0.uploadRate))
                },
            )
            let download = AXDataSeriesDescriptor(
                name: String(localized: "home.traffic.download"),
                isContinuous: true,
                dataPoints: samples.map {
                    AXDataPoint(x: $0.timestamp.timeIntervalSince(start), y: Double($0.downloadRate))
                },
            )
            return AXChartDescriptor(
                title: String(localized: "traffic.label.speed"),
                summary: nil,
                xAxis: xAxis,
                yAxis: yAxis,
                series: [upload, download],
            )
        }
    }

    /// Audio Graph descriptor for the 7-day history bar chart.
    private struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
        let days: [DailyTraffic]

        func makeChartDescriptor() -> AXChartDescriptor {
            let xAxis = AXCategoricalDataAxisDescriptor(
                title: String(localized: "a11y.traffic.chart.axis.day"),
                categoryOrder: days.map(\.date),
            )
            let maxBytes = days.map { max($0.txBytes, $0.rxBytes) }.max() ?? 0
            let yAxis = AXNumericDataAxisDescriptor(
                title: String(localized: "a11y.traffic.chart.axis.data"),
                range: 0 ... Double(max(maxBytes, 1)),
                gridlinePositions: [],
            ) { value in
                ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
            }
            let upload = AXDataSeriesDescriptor(
                name: String(localized: "home.traffic.upload"),
                isContinuous: false,
                dataPoints: days.map { AXDataPoint(x: $0.date, y: Double($0.txBytes)) },
            )
            let download = AXDataSeriesDescriptor(
                name: String(localized: "home.traffic.download"),
                isContinuous: false,
                dataPoints: days.map { AXDataPoint(x: $0.date, y: Double($0.rxBytes)) },
            )
            return AXChartDescriptor(
                title: String(localized: "traffic.label.last7Days"),
                summary: nil,
                xAxis: xAxis,
                yAxis: yAxis,
                series: [upload, download],
            )
        }
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
    let title: LocalizedStringKey
    let tx: Int64
    let rx: Int64
    let identifier: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.smallCaps()).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Label(ByteCountFormatter.string(fromByteCount: tx, countStyle: .binary), systemImage: "arrow.up")
                    .accessibilityIdentifier("\(identifier).tx")
                    .accessibilityLabel(Text("home.traffic.upload"))
                    .accessibilityValue(Text(ByteCountFormatter.string(fromByteCount: tx, countStyle: .binary)))
                Label(ByteCountFormatter.string(fromByteCount: rx, countStyle: .binary), systemImage: "arrow.down")
                    .accessibilityIdentifier("\(identifier).rx")
                    .accessibilityLabel(Text("home.traffic.download"))
                    .accessibilityValue(Text(ByteCountFormatter.string(fromByteCount: rx, countStyle: .binary)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}
