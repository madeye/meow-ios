import Foundation
@testable import meow_ios
import MeowModels
import SwiftData
import Testing

/// `DailyTrafficAccumulator` receives cumulative counter snapshots from the
/// extension and converts them to per-day deltas. The tricky parts:
///
/// - Engine restarts reset counters to zero — never write a negative delta.
/// - The accumulator only lives in the app process, so an app relaunch must
///   reconcile against a durably-persisted baseline instead of silently
///   anchoring on the first post-launch snapshot (issue #291), but only when
///   the persisted baseline is still the *same engine generation* — a
///   restarted engine must not be back-filled.
@Suite("DailyTrafficAccumulator", .tags(.service))
struct TrafficAccumulatorTests {
    // MARK: - Test doubles

    /// Settable clock so tests can control both "now" (bucket keys, baseline
    /// timestamps) and simulate time passing between ingests.
    final class FakeClock {
        var date: Date
        init(_ date: Date) {
            self.date = date
        }

        func now() -> Date {
            date
        }
    }

    /// Settable snapshot + generation source, standing in for the shared
    /// container the real `SharedStoreSnapshotProvider` reads.
    final class FakeSnapshotSource: TrafficSnapshotProviding {
        var snapshot: TrafficSnapshot?
        var generation: Date?
        init(snapshot: TrafficSnapshot? = nil, generation: Date? = nil) {
            self.snapshot = snapshot
            self.generation = generation
        }

        func currentSnapshot() -> TrafficSnapshot? {
            snapshot
        }

        func currentGeneration() -> Date? {
            generation
        }
    }

    /// In-memory baseline store. A single instance shared across two
    /// `DailyTrafficAccumulator`s simulates the durability the real
    /// App-Group-backed store provides across an app relaunch: the second
    /// accumulator instance reads exactly what the first one last persisted.
    final class InMemoryBaselineStore: TrafficBaselineStoring {
        private(set) var baseline: TrafficBaseline?
        func loadBaseline() -> TrafficBaseline? {
            baseline
        }

        func saveBaseline(_ baseline: TrafficBaseline) {
            self.baseline = baseline
        }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DailyTraffic.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        return ModelContext(container)
    }

    private func fetchAll(_ context: ModelContext) throws -> [DailyTraffic] {
        try context.fetch(FetchDescriptor<DailyTraffic>(sortBy: [SortDescriptor(\.date)]))
    }

    // MARK: - Live-session behavior (unchanged from pre-#291 semantics)

    @Test
    @MainActor
    func `first snapshot emits zero delta`() throws {
        let context = try makeContext()
        let source = FakeSnapshotSource(snapshot: .init(uploadBytes: 500, downloadBytes: 900), generation: .init())
        let accumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: source,
            baselineStore: InMemoryBaselineStore(),
        )

        accumulator.start()

        #expect(try fetchAll(context).isEmpty)
    }

    @Test
    @MainActor
    func `subsequent snapshots emit (current − previous)`() throws {
        let context = try makeContext()
        let generation = Date(timeIntervalSince1970: 1000)
        let source = FakeSnapshotSource(snapshot: .init(uploadBytes: 100, downloadBytes: 200), generation: generation)
        let accumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: source,
            baselineStore: InMemoryBaselineStore(),
        )
        accumulator.start()

        source.snapshot = .init(uploadBytes: 250, downloadBytes: 260)
        accumulator.ingestCurrent()

        let rows = try fetchAll(context)
        #expect(rows.count == 1)
        #expect(rows.first?.txBytes == 150)
        #expect(rows.first?.rxBytes == 60)
    }

    @Test
    @MainActor
    func `counter reset produces zero delta, never negative`() throws {
        let context = try makeContext()
        let generation = Date(timeIntervalSince1970: 1000)
        let source = FakeSnapshotSource(snapshot: .init(uploadBytes: 500, downloadBytes: 500), generation: generation)
        let accumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: source,
            baselineStore: InMemoryBaselineStore(),
        )
        accumulator.start()
        source.snapshot = .init(uploadBytes: 700, downloadBytes: 700)
        accumulator.ingestCurrent()

        // Engine restarts; counters drop back near zero.
        source.snapshot = .init(uploadBytes: 10, downloadBytes: 5)
        accumulator.ingestCurrent()

        let rows = try fetchAll(context)
        #expect(rows.count == 1)
        #expect(rows.first?.txBytes == 200)
        #expect(rows.first?.rxBytes == 200)

        // The re-anchored counters are diffable going forward.
        source.snapshot = .init(uploadBytes: 40, downloadBytes: 35)
        accumulator.ingestCurrent()
        let rowsAfter = try fetchAll(context)
        #expect(rowsAfter.first?.txBytes == 230)
        #expect(rowsAfter.first?.rxBytes == 230)
    }

    // MARK: - App-relaunch reconciliation (issue #291)

    @Test
    @MainActor
    func `app relaunch with the same engine generation credits the offline delta`() throws {
        let context = try makeContext()
        let generation = Date(timeIntervalSince1970: 1000)
        let baselineStore = InMemoryBaselineStore()
        let clock = FakeClock(Date(timeIntervalSince1970: 100_000))

        // First app process: connects, ingests once, then is killed.
        let firstSource = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 1000, downloadBytes: 2000),
            generation: generation,
        )
        let firstAccumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: firstSource,
            baselineStore: baselineStore,
            now: clock.now,
        )
        firstAccumulator.start()
        #expect(baselineStore.baseline?.uploadBytes == 1000)
        #expect(baselineStore.baseline?.generation == generation)

        // App is dead; the extension keeps running and counters keep
        // climbing. Time also advances.
        clock.date = Date(timeIntervalSince1970: 100_500)
        let secondSource = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 1600, downloadBytes: 2900),
            generation: generation,
        )
        let secondAccumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: secondSource,
            baselineStore: baselineStore,
            now: clock.now,
        )

        // New process, new accumulator instance, but the *same* baseline
        // storage — simulates the app relaunching.
        secondAccumulator.start()

        let rows = try fetchAll(context)
        #expect(rows.count == 1)
        #expect(rows.first?.txBytes == 600)
        #expect(rows.first?.rxBytes == 900)
    }

    @Test
    @MainActor
    func `app relaunch after an engine restart does not credit the gap`() throws {
        let context = try makeContext()
        let baselineStore = InMemoryBaselineStore()
        let clock = FakeClock(Date(timeIntervalSince1970: 100_000))

        let firstSource = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 1000, downloadBytes: 2000),
            generation: Date(timeIntervalSince1970: 1000),
        )
        let firstAccumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: firstSource,
            baselineStore: baselineStore,
            now: clock.now,
        )
        firstAccumulator.start()

        // The engine (and the tunnel connection) restarted while the app was
        // dead — a brand-new generation, and the counters reset near zero.
        clock.date = Date(timeIntervalSince1970: 100_500)
        let secondSource = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 50, downloadBytes: 80),
            generation: Date(timeIntervalSince1970: 2000),
        )
        let secondAccumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: secondSource,
            baselineStore: baselineStore,
            now: clock.now,
        )
        secondAccumulator.start()

        // No delta credited for the gap — only future ingests (against the
        // new generation's own anchor) should produce history.
        #expect(try fetchAll(context).isEmpty)
        #expect(baselineStore.baseline?.generation == Date(timeIntervalSince1970: 2000))

        secondSource.snapshot = .init(uploadBytes: 90, downloadBytes: 130)
        secondAccumulator.ingestCurrent()
        let rows = try fetchAll(context)
        #expect(rows.count == 1)
        #expect(rows.first?.txBytes == 40)
        #expect(rows.first?.rxBytes == 50)
    }

    @Test
    @MainActor
    func `first launch ever with no persisted baseline just anchors`() throws {
        let context = try makeContext()
        let source = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 12345, downloadBytes: 6789),
            generation: Date(timeIntervalSince1970: 1000),
        )
        let accumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: source,
            baselineStore: InMemoryBaselineStore(),
        )

        accumulator.start()

        #expect(try fetchAll(context).isEmpty)
    }

    @Test
    @MainActor
    func `relaunch reconciliation crossing midnight splits the credit across both days`() throws {
        let context = try makeContext()
        let baselineStore = InMemoryBaselineStore()
        let generation = Date(timeIntervalSince1970: 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // Baseline captured at 22:00 on day 1.
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 22))!
        let clock = FakeClock(day1)
        let firstSource = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 1000, downloadBytes: 0),
            generation: generation,
        )
        let firstAccumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: firstSource,
            baselineStore: baselineStore,
            calendar: calendar,
            now: clock.now,
        )
        firstAccumulator.start()

        // App relaunches at 02:00 on day 2 — a 4-hour offline gap, split
        // 2 hours before midnight / 2 hours after.
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 2))!
        clock.date = day2
        let secondSource = FakeSnapshotSource(
            snapshot: .init(uploadBytes: 2000, downloadBytes: 0),
            generation: generation,
        )
        let secondAccumulator = DailyTrafficAccumulator(
            modelContext: context,
            snapshotProvider: secondSource,
            baselineStore: baselineStore,
            calendar: calendar,
            now: clock.now,
        )
        secondAccumulator.start()

        let rows = try fetchAll(context)
        #expect(rows.count == 2)
        #expect(rows.map(\.txBytes).sorted() == [500, 500])
        #expect(rows.reduce(0) { $0 + $1.txBytes } == 1000)
    }

    // MARK: - TrafficDaySplit (midnight-attribution policy)

    @Test
    func `TrafficDaySplit keeps a same-day interval in a single bucket`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 9))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 17))!

        let credits = TrafficDaySplit.credits(deltaUp: 1000, deltaDown: 200, from: start, to: end, calendar: calendar)

        #expect(credits.count == 1)
        #expect(credits.first?.up == 1000)
        #expect(credits.first?.down == 200)
    }

    @Test
    func `TrafficDaySplit divides bytes proportionally and never loses a byte to rounding`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 3-day span: 6h on day 1, 24h on day 2, 6h on day 3 (36h total).
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 18))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 6))!

        let credits = TrafficDaySplit.credits(deltaUp: 1001, deltaDown: 999, from: start, to: end, calendar: calendar)

        #expect(credits.count == 3)
        #expect(credits.reduce(0) { $0 + $1.up } == 1001)
        #expect(credits.reduce(0) { $0 + $1.down } == 999)
        // Middle day carries the largest share (2/3 of the interval).
        #expect(credits[1].up > credits[0].up)
        #expect(credits[1].up > credits[2].up)
    }
}
