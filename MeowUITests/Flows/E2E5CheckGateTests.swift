import XCTest
import MeowModels

/// The five-check connectivity gate (TEST_STRATEGY §6.2, §7.6) driven on
/// a virtual iPhone via vphone-cli. Direct parity target:
/// `/Volumes/DATA/workspace/meow-go/test-e2e.sh`.
///
/// This file defines the iOS-side *assertion shape*; the actual socket
/// interactions happen through `VPhone` (see `Support/VPhone.swift`).
/// The checks map 1:1 onto the PRD §4.4 Diagnostics Surface Contract:
/// if any label key here drifts from the `DiagnosticsCheck` enum, this
/// file fails to compile — that's intentional.
///
/// Status: STUB — all cases disabled until T2.6 Debug Diagnostics Panel
/// + T4.2 Home Screen + Tart base image are ready. When enabled, this
/// suite runs only in the nightly `e2e` job, not on PRs.
final class E2E5CheckGateTests: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        // Skip by default — this bundle is only built into the nightly run.
        if ProcessInfo.processInfo.environment["MEOW_E2E_VPHONE"] == nil {
            return XCTestSuite(name: "E2E5CheckGateTests (skipped — set MEOW_E2E_VPHONE=1)")
        }
        return super.defaultTestSuite
    }

    // MARK: PRD §4.4 frozen contract — all 5 checks in display order

    func test01_tunExists() throws {
        try assertDiagnosticsPass(.tunExists)
    }

    func test02_dnsOk() throws {
        try assertDiagnosticsPass(.dnsOk)
    }

    func test03_tcpProxyOk() throws {
        try assertDiagnosticsPass(.tcpProxyOk)
    }

    func test04_http204Ok() throws {
        try assertDiagnosticsPass(.http204Ok)
    }

    func test05_memOk() throws {
        // PRD §4.4 threshold: PASS iff extension resident memory ≤ 14 MB.
        // Any sample ≥ 15 MB is reported as FAIL(mem=NNmb>=15mb); see
        // TEST_STRATEGY §8.1 — this is a ship-blocker, not a regression.
        try assertDiagnosticsPass(.memOk)
    }

    // MARK: Contract guard

    /// Compile-time check that we reference every frozen key. If PRD
    /// §4.4 adds a check, this test fails until someone adds a case
    /// above — so "we forgot to test a new check" becomes impossible.
    func test99_allFrozenKeysCovered() {
        let covered: Set<DiagnosticsCheck> = [
            .tunExists, .dnsOk, .tcpProxyOk, .http204Ok, .memOk
        ]
        XCTAssertEqual(
            covered, Set(DiagnosticsCheck.allCases),
            "PRD §4.4 added a diagnostics check without a matching test — add one above"
        )
    }

    // MARK: Helper

    private func assertDiagnosticsPass(_ check: DiagnosticsCheck, file: StaticString = #filePath, line: UInt = #line) throws {
        throw XCTSkip("blocked on T2.6 diagnostics panel + Tart image")

        // When T2.6 + Tart image land, the body becomes roughly:
        //
        //   let phone = VPhone()
        //   try phone.home.tapConnect()
        //   try phone.home.waitForConnected()
        //   try phone.diagnostics.navigate()
        //   try phone.diagnostics.tapRun()
        //   let results = try phone.diagnostics.readResults()
        //   XCTAssertEqual(results[check], .pass,
        //                  "\(check.rawValue) failed: \(results[check] ?? .fail(reason: "missing"))",
        //                  file: file, line: line)
    }
}
