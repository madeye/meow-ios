import XCTest

/// The five-check connectivity gate (TEST_STRATEGY §6.2, §7.6) driven on
/// a virtual iPhone via vphone-cli. Direct parity target:
/// `/Volumes/DATA/workspace/meow-go/test-e2e.sh`.
///
/// This file defines the iOS-side *assertion shape*; the actual socket
/// interactions happen through `VPhone` (see `Support/VPhone.swift`).
/// The tests deliberately do NOT attempt to observe TUN state from
/// outside the device — the app's in-app diagnostics panel (T3.6) is
/// the signal surface. This keeps the harness reproducible across iOS
/// versions.
///
/// Status: STUB — all cases disabled until T3.6 diagnostics panel +
/// T3.7 UI stabilization + Tart base image are ready. When enabled,
/// this suite runs only in the nightly `e2e` job, not on PRs.
final class E2E5CheckGateTests: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        // Skip by default — this bundle is only built into the nightly run.
        if ProcessInfo.processInfo.environment["MEOW_E2E_VPHONE"] == nil {
            return XCTestSuite(name: "E2E5CheckGateTests (skipped — set MEOW_E2E_VPHONE=1)")
        }
        return super.defaultTestSuite
    }

    // MARK: 5-check gate — one test per Android parity check

    func test01_tunInterfaceUp() throws {
        // Connect, then assert diagnostics row "TUN up" == PASS.
        throw XCTSkip("blocked on T3.6 + T3.7 + Tart image")
    }

    func test02_dnsResolvesThroughTunnel() throws {
        throw XCTSkip("blocked on T3.6")
    }

    func test03_tcpReach_1_1_1_1_80() throws {
        throw XCTSkip("blocked on T3.6")
    }

    func test04_tcpReach_8_8_8_8_443() throws {
        throw XCTSkip("blocked on T3.6")
    }

    func test05_httpGenerate204() throws {
        throw XCTSkip("blocked on T3.6")
    }

    // MARK: Performance guardrail — 15 MB extension memory ceiling

    func test06_extensionResidentMemoryUnder15MB() throws {
        // After connect, repeatedly sample extension RSS via
        // diagnostics panel; any sample ≥ 15 MB fails the test.
        // See TEST_STRATEGY §8.1.
        throw XCTSkip("blocked on T3.6 memory probe affordance")
    }
}
