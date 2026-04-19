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
/// - **Engine restart** — new cumulative is lower than the previous anchor.
///   We re-anchor to the new value and skip the delta (otherwise a restart
///   would produce a large negative delta and appear as traffic loss).
/// - **Midnight rollover** — the bucket key is recomputed on every write via
///   `DailyTraffic.key(for: .now)`, so the first delta after 00:00 naturally
///   lands in the new day's bucket without a scheduler.
@MainActor
final class DailyTrafficAccumulator {
    private let modelContext: ModelContext
    private let log = Logger(subsystem: "io.github.madeye.meow.app", category: "daily-traffic")

    private var lastUp: Int64 = 0
    private var lastDown: Int64 = 0
    private var haveAnchor = false
    private var observer: DarwinObserver?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func start() {
        // Seed the anchor from whatever's currently in the shared store so the
        // first post-start delta doesn't double-count the cumulative counter.
        ingestCurrent()
        observer = DarwinBridge.addObserver(for: .traffic) { [weak self] in
            Task { @MainActor in self?.ingestCurrent() }
        }
    }

    func stop() {
        observer.map { DarwinBridge.removeObserver($0) }
        observer = nil
    }

    private func ingestCurrent() {
        guard let snapshot = SharedStore.readTraffic() else { return }
        defer {
            lastUp = snapshot.uploadBytes
            lastDown = snapshot.downloadBytes
            haveAnchor = true
        }

        // First snapshot after start(): just anchor, no delta yet.
        guard haveAnchor else { return }

        // Counter reset (engine restart). Re-anchor, don't back-fill.
        if snapshot.uploadBytes < lastUp || snapshot.downloadBytes < lastDown {
            log.notice("counter reset detected — re-anchoring without writing a delta")
            return
        }

        let deltaUp = snapshot.uploadBytes - lastUp
        let deltaDown = snapshot.downloadBytes - lastDown
        if deltaUp == 0, deltaDown == 0 { return }

        let key = DailyTraffic.key(for: .now)
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
            entry.txBytes += deltaUp
            entry.rxBytes += deltaDown
            try modelContext.save()
        } catch {
            log.error("bucket write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
