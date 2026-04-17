import Testing
import Foundation

/// `TrafficAccumulator` receives raw counter snapshots from the extension
/// and converts them to per-day deltas. Delta logic is the tricky part —
/// engine restarts reset counters to zero, and we must not write negatives.
@Suite("TrafficAccumulator", .tags(.service))
struct TrafficAccumulatorTests {

    @Test("first snapshot emits zero delta", .disabled("blocked on T4.6"))
    func testFirstSnapshotZeroDelta() {
        // expect recorded delta == 0 on first call
    }

    @Test("subsequent snapshots emit (current − previous)", .disabled("blocked on T4.6"))
    func testDeltaArithmetic() {
        // record(tx: 100), record(tx: 250) → delta 150
    }

    @Test("counter reset produces zero delta, never negative", .disabled("blocked on T4.6"))
    func testCounterResetNotNegative() {
        // record(tx: 500), then engine restarts and record(tx: 10) → delta 0, baseline rebases to 10
    }

    @Test("crossing midnight writes a new DailyTraffic row", .disabled("blocked on T4.6"))
    func testMidnightRollover() {
        // seed with date X, advance clock past midnight, record again → two rows
    }

    @Test("30-second batched flush coalesces writes", .disabled("blocked on T4.6"))
    func testBatchedFlush() {
        // 10 records within 30s → exactly one SwiftData write
    }
}
