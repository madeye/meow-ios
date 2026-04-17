import Foundation
import Testing

/// `TrafficAccumulator` receives raw counter snapshots from the extension
/// and converts them to per-day deltas. Delta logic is the tricky part —
/// engine restarts reset counters to zero, and we must not write negatives.
@Suite("TrafficAccumulator", .tags(.service))
struct TrafficAccumulatorTests {
    @Test(.disabled("blocked on T4.6"))
    func `first snapshot emits zero delta`() {
        // expect recorded delta == 0 on first call
    }

    @Test(.disabled("blocked on T4.6"))
    func `subsequent snapshots emit (current − previous)`() {
        // record(tx: 100), record(tx: 250) → delta 150
    }

    @Test(.disabled("blocked on T4.6"))
    func `counter reset produces zero delta, never negative`() {
        // record(tx: 500), then engine restarts and record(tx: 10) → delta 0, baseline rebases to 10
    }

    @Test(.disabled("blocked on T4.6"))
    func `crossing midnight writes a new DailyTraffic row`() {
        // seed with date X, advance clock past midnight, record again → two rows
    }

    @Test(.disabled("blocked on T4.6"))
    func `30-second batched flush coalesces writes`() {
        // 10 records within 30s → exactly one SwiftData write
    }
}
