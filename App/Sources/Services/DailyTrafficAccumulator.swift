import Foundation
import MeowIPC
import MeowModels
import os
import SwiftData

/// Rolls the extension's cumulative upload/download counters into per-day
/// `DailyTraffic` buckets that back `TrafficView`'s history charts. Without
/// this accumulator the `@Query` in `TrafficView` never populates and the
/// view shows the empty state even while the tunnel is busy.
///
/// The extension publishes cumulative bytes since *its* engine last started
/// (via the shared-container snapshot + `.traffic` Darwin notification). We
/// diff successive snapshots and add the delta to today's bucket. Edge cases:
///
/// - **Engine restart mid-session** — new cumulative is lower than the
///   previous in-memory anchor. We re-anchor to the new value and skip the
///   delta (otherwise a restart would produce a large negative delta and
///   appear as traffic loss).
/// - **Midnight rollover during a live tick** — ticks arrive every ~500ms, so
///   the bucket key recomputed on every write via `DailyTraffic.key(for:)`
///   naturally lands in the new day's bucket without a scheduler.
/// - **App relaunch while the tunnel kept running** (issue #291) — this
///   accumulator only lives in the app process. The extension keeps counting
///   while the app is suspended or terminated, so the *first* snapshot after
///   a fresh launch used to be anchored with zero delta, silently dropping
///   every byte transferred while the app was dead. We now persist a
///   reconciliation baseline (`TrafficBaseline`) to the App Group on every
///   ingest, and on the first ingest after `start()` we diff against that
///   baseline instead of just anchoring — see `reconcileAfterRelaunch`.
@MainActor
final class DailyTrafficAccumulator {
    private let modelContext: ModelContext
    private let snapshotProvider: TrafficSnapshotProviding
    private let baselineStore: TrafficBaselineStoring
    private let calendar: Calendar
    private let now: () -> Date
    private let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "daily-traffic")

    private var lastUp: Int64 = 0
    private var lastDown: Int64 = 0
    private var haveAnchor = false
    private var observer: DarwinObserver?

    init(
        modelContext: ModelContext,
        snapshotProvider: TrafficSnapshotProviding = SharedStoreSnapshotProvider(),
        baselineStore: TrafficBaselineStoring = SharedStoreTrafficBaselineStore(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
    ) {
        self.modelContext = modelContext
        self.snapshotProvider = snapshotProvider
        self.baselineStore = baselineStore
        self.calendar = calendar
        self.now = now
    }

    func start() {
        // The first ingest after start() reconciles against whatever
        // baseline survived from the previous process instead of just
        // anchoring — see `reconcileAfterRelaunch`.
        ingestCurrent()
        observer = DarwinBridge.addObserver(for: .traffic) { [weak self] in
            Task { @MainActor in self?.ingestCurrent() }
        }
    }

    func stop() {
        observer.map { DarwinBridge.removeObserver($0) }
        observer = nil
    }

    /// Not private: `TrafficAccumulatorTests` calls this directly to
    /// simulate a `.traffic` Darwin-notification tick without wiring the
    /// real notification path.
    func ingestCurrent() {
        guard let snapshot = snapshotProvider.currentSnapshot() else { return }
        let generation = snapshotProvider.currentGeneration()
        let timestamp = now()

        defer {
            lastUp = snapshot.uploadBytes
            lastDown = snapshot.downloadBytes
            haveAnchor = true
            // Persist the fresh baseline on every ingest (not just at
            // start()) so a later app kill reconciles from a near-real-time
            // anchor rather than replaying bytes already credited in this
            // session.
            baselineStore.saveBaseline(TrafficBaseline(
                uploadBytes: snapshot.uploadBytes,
                downloadBytes: snapshot.downloadBytes,
                generation: generation,
                capturedAt: timestamp,
            ))
        }

        guard haveAnchor else {
            reconcileAfterRelaunch(current: snapshot, generation: generation, at: timestamp)
            return
        }

        // Counter reset (engine restart) mid-session. Re-anchor, don't back-fill.
        if snapshot.uploadBytes < lastUp || snapshot.downloadBytes < lastDown {
            log.notice("counter reset detected — re-anchoring without writing a delta")
            return
        }

        let deltaUp = snapshot.uploadBytes - lastUp
        let deltaDown = snapshot.downloadBytes - lastDown
        creditToday(deltaUp: deltaUp, deltaDown: deltaDown, at: timestamp)
    }

    /// Handles the first snapshot ingested since this accumulator instance
    /// was created — i.e. right after `start()`, which for the app this is
    /// always either a fresh install or a relaunch. Reconciles the persisted
    /// baseline (if any) against the current cumulative counters:
    ///
    /// - No persisted baseline → nothing to reconcile (fresh install, or the
    ///   app has never ingested a snapshot before). Anchor only.
    /// - Persisted baseline with a *different* (or unknown) engine
    ///   generation → the extension's engine was stopped and restarted since
    ///   the baseline was captured, so the counters may have reset. We never
    ///   diff across a generation change — anchor only.
    /// - Persisted baseline with the *same* generation but counters that
    ///   went backwards → shouldn't happen for a continuously-running
    ///   engine, but if it does we anchor only rather than risk a negative
    ///   delta.
    /// - Persisted baseline with the same generation and counters that
    ///   advanced → the engine kept counting while the app was dead. Credit
    ///   the delta to history, attributed across the day(s) the offline
    ///   interval spanned (see `TrafficDaySplit`).
    private func reconcileAfterRelaunch(current: TrafficSnapshot, generation: Date?, at timestamp: Date) {
        guard let baseline = baselineStore.loadBaseline() else { return }

        guard
            let baselineGeneration = baseline.generation,
            let generation,
            generation == baselineGeneration
        else {
            log.notice("engine generation changed since last run — anchoring without a relaunch delta")
            return
        }

        guard current.uploadBytes >= baseline.uploadBytes, current.downloadBytes >= baseline.downloadBytes else {
            log.notice("counters went backwards for an unchanged engine generation — anchoring without a delta")
            return
        }

        let deltaUp = current.uploadBytes - baseline.uploadBytes
        let deltaDown = current.downloadBytes - baseline.downloadBytes
        guard deltaUp != 0 || deltaDown != 0 else { return }

        log.notice(
            "crediting offline bytes: up=\(deltaUp, privacy: .public) down=\(deltaDown, privacy: .public)",
        )

        for credit in TrafficDaySplit.credits(
            deltaUp: deltaUp,
            deltaDown: deltaDown,
            from: baseline.capturedAt,
            to: timestamp,
            calendar: calendar,
        ) {
            writeBucket(key: credit.key, up: credit.up, down: credit.down)
        }
    }

    private func creditToday(deltaUp: Int64, deltaDown: Int64, at timestamp: Date) {
        guard deltaUp != 0 || deltaDown != 0 else { return }
        writeBucket(key: DailyTraffic.key(for: timestamp, calendar: calendar), up: deltaUp, down: deltaDown)
    }

    private func writeBucket(key: String, up: Int64, down: Int64) {
        let predicate = #Predicate<DailyTraffic> { $0.date == key }
        let descriptor = FetchDescriptor<DailyTraffic>(predicate: predicate)
        do {
            let entry: DailyTraffic
            if let existing = try modelContext.fetch(descriptor).first {
                entry = existing
            } else {
                entry = DailyTraffic(date: key)
                modelContext.insert(entry)
            }
            entry.txBytes += up
            entry.rxBytes += down
            try modelContext.save()
        } catch {
            log.error("bucket write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Abstracts the extension's shared-container traffic snapshot so tests can
/// supply canned sequences without touching the real App Group (which
/// `fatalError`s without the App Group entitlement).
protocol TrafficSnapshotProviding {
    func currentSnapshot() -> TrafficSnapshot?
    /// The engine-generation identity associated with `currentSnapshot()` —
    /// see `TrafficBaseline.generation`.
    func currentGeneration() -> Date?
}

/// Production `TrafficSnapshotProviding`: reads the extension's live traffic
/// snapshot and `VpnState.startedAt` from the shared container.
struct SharedStoreSnapshotProvider: TrafficSnapshotProviding {
    func currentSnapshot() -> TrafficSnapshot? {
        SharedStore.readTraffic()
    }

    func currentGeneration() -> Date? {
        SharedStore.readState()?.startedAt
    }
}

/// Abstracts persistence of `DailyTrafficAccumulator`'s reconciliation
/// baseline so tests can substitute in-memory storage instead of the real
/// App Group `UserDefaults` suite.
protocol TrafficBaselineStoring {
    func loadBaseline() -> TrafficBaseline?
    func saveBaseline(_ baseline: TrafficBaseline)
}

/// Production `TrafficBaselineStoring`: the App Group `UserDefaults` suite,
/// via `SharedStore`.
struct SharedStoreTrafficBaselineStore: TrafficBaselineStoring {
    func loadBaseline() -> TrafficBaseline? {
        SharedStore.readTrafficBaseline()
    }

    func saveBaseline(_ baseline: TrafficBaseline) {
        try? SharedStore.writeTrafficBaseline(baseline)
    }
}

/// The midnight-attribution policy for crediting a byte delta that may span
/// an offline interval longer than a single day.
///
/// We don't know *when* within `[start, end)` the bytes actually moved —
/// the extension only exposes a cumulative counter, not per-day buckets —
/// so we attribute the delta to each calendar day proportionally by the
/// fraction of wall-clock time that fell on that day. This degrades to "all
/// of it on today" for same-day intervals (the overwhelmingly common case:
/// every live tick, and most relaunches), and only actually splits across
/// multiple `DailyTraffic` rows when an offline gap crossed midnight.
/// Rounding remainders are assigned to the final day in the split so the
/// sum of credited bytes always exactly equals the input delta — we never
/// fabricate or lose bytes.
enum TrafficDaySplit {
    /// One `DailyTraffic` bucket's share of a split delta.
    struct DayCredit: Equatable {
        var key: String
        var up: Int64
        var down: Int64
    }

    static func credits(
        deltaUp: Int64,
        deltaDown: Int64,
        from start: Date,
        to end: Date,
        calendar: Calendar,
    ) -> [DayCredit] {
        guard deltaUp != 0 || deltaDown != 0 else { return [] }

        let fractions = dayFractions(from: start, to: end, calendar: calendar)
        guard fractions.count > 1 else {
            return fractions.map { DayCredit(key: $0.key, up: deltaUp, down: deltaDown) }
        }

        let upShares = split(deltaUp, fractions: fractions.map(\.fraction))
        let downShares = split(deltaDown, fractions: fractions.map(\.fraction))
        return fractions.indices.map { index in
            DayCredit(key: fractions[index].key, up: upShares[index], down: downShares[index])
        }
    }

    private static func dayFractions(
        from start: Date,
        to end: Date,
        calendar: Calendar,
    ) -> [(key: String, fraction: Double)] {
        guard end > start else {
            return [(DailyTraffic.key(for: end, calendar: calendar), 1.0)]
        }

        let total = end.timeIntervalSince(start)
        var result: [(String, Double)] = []
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(nextDayStart, end)
            let fraction = segmentEnd.timeIntervalSince(cursor) / total
            result.append((DailyTraffic.key(for: cursor, calendar: calendar), fraction))
            cursor = segmentEnd
        }
        return result
    }

    private static func split(_ total: Int64, fractions: [Double]) -> [Int64] {
        guard total != 0 else { return fractions.map { _ in 0 } }
        var shares: [Int64] = []
        var allocated: Int64 = 0
        for (index, fraction) in fractions.enumerated() {
            if index == fractions.count - 1 {
                shares.append(total - allocated)
            } else {
                let share = Int64((Double(total) * fraction).rounded())
                shares.append(share)
                allocated += share
            }
        }
        return shares
    }
}
