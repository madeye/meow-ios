import XCTest
import SwiftData

/// SwiftData under concurrent access from the app (writer) and the extension
/// (reader for config selection). Also covers large-dataset query latency.
final class ConcurrentAccessTests: XCTestCase {

    func testProfileWriteWhileExtensionReadsNoCrash() async throws {
        throw XCTSkip("blocked on T4.1")
    }

    func testDailyTraffic10kRowsMonthlyQueryUnder100ms() async throws {
        throw XCTSkip("blocked on T4.1")
    }

    func testContainerRecreationPreservesIntegrity() async throws {
        throw XCTSkip("blocked on T4.1")
    }
}
