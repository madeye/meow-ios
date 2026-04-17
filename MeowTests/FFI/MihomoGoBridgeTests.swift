import Testing
import Foundation

/// Smoke tests for the Go `mihomo-core` static library. Lifecycle tests
/// (start, running, stop, counters, error propagation) live here; deeper
/// integration tests that exercise the full proxy engine belong in
/// `MeowIntegrationTests/EngineIntegration/`.
@Suite("mihomo-core Go bridge", .tags(.ffi))
struct MihomoGoBridgeTests {

    @Test("meowEngineStart rejects missing config file", .disabled("blocked on T2.4 xcframework"))
    func testEngineStartMissingFile() {
        // let rc = meowEngineStart("/tmp/does-not-exist.yaml", "")
        // #expect(rc != 0)
    }

    @Test("meowIsRunning reflects real state", .disabled("blocked on T2.4"))
    func testIsRunningReflectsState() {
        // start with tmp config → expect true → stop → expect false
    }

    @Test("meowGetUploadTraffic is monotonic within a session", .disabled("blocked on T2.4"))
    func testCountersMonotonic() {
        // read twice after idle; second ≥ first
    }

    @Test("meowGetLastError mirrors engine error", .disabled("blocked on T2.4"))
    func testLastErrorMirrorsEngine() {
        // force a start failure; last_error should contain specific message
    }
}
