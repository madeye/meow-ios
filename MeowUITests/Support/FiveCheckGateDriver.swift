import Foundation
import MeowModels

/// T4.2 navigation seam — the only UI-surface step in the five-check gate
/// whose selectors aren't known at this point in the milestone. When T4.2
/// (Home Screen) + T2.6 (Debug Diagnostics Panel) land, Dev wires up a
/// concrete closure that taps through whatever the shipping entry point
/// turns out to be (tab-bar button, settings menu, gear icon, long-press,
/// shake gesture — TBD). The driver never touches those anchors directly;
/// everything else in the state machine is anchor-independent.
///
/// Mirrors the `drive(proxy:assertion:)` stub pattern in
/// `MeowIntegrationTests/ProtocolFixtures/UDPProtocolTests.swift`:
/// abstract the unknown, exercise the known.
typealias NavigateToDiagnostics = (VPhone) throws -> Void

/// Anchor-independent driver for the 5-check diagnostics gate
/// (TEST_STRATEGY §6.2 / §7.6; PRD §4.4 frozen label contract). Composes
/// the vphone-cli primitives in `VPhone` into a complete install → assert
/// state machine, with the sole T4.2-dependent step abstracted via a
/// `NavigateToDiagnostics` closure.
///
/// Shared between two suites so the state machine is written once:
///   - `MeowUITests/Flows/E2E5CheckGateTests.swift` (asserts all 5 rows PASS)
///   - future UDP protocol tests in
///     `MeowIntegrationTests/ProtocolFixtures/UDPProtocolTests.swift`
///     (asserts a subset per protocol — handshake → TCP_PROXY_OK,
///     http204 → HTTP_204_OK, dohThroughTunnel → DNS_OK), enabled once
///     T2.9 unblocks non-DNS UDP forwarding.
///
/// ## State machine
///
///   installProfile            → vphone-cli handles the `meow://connect` deep link
///   connect                   → tap the Home Screen VPN toggle
///   waitForRunning            → block until is_running == 1
///   navigateToDiagnosticsPanel→ T4.2 seam (injected closure)
///   runDiagnosticsAndParse    → trigger the run and parse §4.4 labels
///   disconnect                → return to idle
///   teardown                  → hook for future log dumps / screenshots
///
/// The phase boundaries are the stable contract; any one step's backing
/// mechanism may evolve (e.g. `waitForRunning` could move from a Home
/// Screen label to the REST external-controller `/configs` surface)
/// without the caller changing.
///
/// ## Usage
///
///     let driver = FiveCheckGateDriver(
///         phone: VPhone(),
///         subscriptionDeepLink: URL(string: "meow://connect?url=\(encoded)")!,
///         navigateToDiagnostics: { phone in
///             // T4.2 concrete — e.g. settingsTab → "Debug" → "Diagnostics"
///             try phone.tap(x: 0, y: 0)
///         }
///     )
///     let results = try driver.runToResults()
///     // Caller picks whichever rows they care about:
///     XCTAssertEqual(results[.tcpProxyOk], .pass)
struct FiveCheckGateDriver {
    let phone: VPhone
    let subscriptionDeepLink: URL
    let navigateToDiagnostics: NavigateToDiagnostics
    var connectTimeout: TimeInterval = 10
    var diagnosticsReadTimeout: TimeInterval = 20

    enum DriverError: Error, CustomStringConvertible {
        case stillNotRunning(after: TimeInterval)
        case diagnosticsUnreadable(underlying: Error)
        case rowsFailed([DiagnosticsCheck: DiagnosticsResult])

        var description: String {
            switch self {
            case .stillNotRunning(let t):
                return "is_running did not reach 1 within \(t)s after connect()"
            case .diagnosticsUnreadable(let underlying):
                return "diagnostics panel unreadable: \(underlying)"
            case .rowsFailed(let rows):
                let failed = rows
                    .filter { if case .pass = $0.value { return false } else { return true } }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .sorted()
                    .joined(separator: ", ")
                return "one or more §4.4 rows did not PASS: [\(failed)]"
            }
        }
    }

    // MARK: State-machine phases

    /// Step 1. vphone-cli's `openURL` invokes iOS's URL handler, which
    /// routes `meow://connect?url=…` into the app's subscription import.
    func installProfile() throws {
        try phone.openURL(subscriptionDeepLink)
    }

    /// Step 2. The Home Screen page object owns the tap coordinates —
    /// the driver doesn't hard-code them, so T4.2 layout changes ripple
    /// through `HomeScreen.tapConnect()` alone.
    func connect() throws {
        try phone.home.tapConnect()
    }

    /// Step 3. Block until the extension reports running. The current
    /// backing mechanism is `HomeScreen.waitForConnected`, which will
    /// resolve once T4.2 lands the "Connected" anchor. If the REST
    /// external-controller path (`/configs`, `is_running == 1`) becomes
    /// preferable later, swap the impl behind this phase — the driver's
    /// contract with callers is unchanged.
    func waitForRunning(timeout: TimeInterval? = nil) throws {
        let t = timeout ?? connectTimeout
        do {
            try phone.home.waitForConnected(timeout: t)
        } catch {
            throw DriverError.stillNotRunning(after: t)
        }
    }

    /// Step 4. The one T4.2-dependent step. Concrete closure taps
    /// through whatever navigation pattern ships.
    func navigateToDiagnosticsPanel() throws {
        try navigateToDiagnostics(phone)
    }

    /// Step 5. Trigger the run, parse the §4.4 labels, surface any
    /// parser error as `.diagnosticsUnreadable` so the caller can
    /// distinguish "panel didn't render / OCR garbled" from "a check
    /// returned FAIL" (which surfaces as a value in the returned map).
    func runDiagnosticsAndParse(timeout: TimeInterval? = nil) throws -> [DiagnosticsCheck: DiagnosticsResult] {
        try phone.diagnostics.tapRun()
        do {
            return try phone.diagnostics.readResults(timeout: timeout ?? diagnosticsReadTimeout)
        } catch {
            throw DriverError.diagnosticsUnreadable(underlying: error)
        }
    }

    /// Step 6. Return the Home Screen to idle. Idempotent — safe from a
    /// test's `tearDown` even if an earlier phase threw.
    func disconnect() throws {
        try phone.home.tapConnect()
    }

    /// Step 7. Explicit hook for future teardown (log dump, on-fail
    /// screenshot, fixture-side PID reap). Intentionally empty today —
    /// the phase boundary is what matters; splitting it from `disconnect`
    /// means callers don't have to grow a second wrapper when the hook
    /// picks up real work.
    func teardown() throws {
        // no-op
    }

    // MARK: Convenience composition

    /// Run the full state machine and return the parsed results. Callers
    /// assert whichever checks they care about. SS/Trojan/VLESS/VMess
    /// tests assert all five; UDP protocol tests (post-T2.9) assert
    /// handshake / http204 / DoH subsets per protocol.
    func runToResults() throws -> [DiagnosticsCheck: DiagnosticsResult] {
        try installProfile()
        try connect()
        try waitForRunning()
        try navigateToDiagnosticsPanel()
        let results = try runDiagnosticsAndParse()
        try disconnect()
        try teardown()
        return results
    }

    /// Convenience for the SS/Trojan/VLESS/VMess `E2E5CheckGateTests`
    /// path: run the full machine, then fail if any §4.4 row isn't PASS.
    /// Throws `DriverError.rowsFailed` with the full failing-row map for
    /// diagnosis. Pure composition over `runToResults()` + `assertAllPass`,
    /// exposed as a one-liner for test-site ergonomics.
    func runAndAssertAllPass() throws {
        let results = try runToResults()
        try Self.assertAllPass(results)
    }

    /// Pure helper — no vphone-cli interaction. Fails if any §4.4 row is
    /// not `.pass`. Separate from the state machine so it's trivially
    /// unit-testable and reusable by callers that got a results map
    /// through some other path.
    static func assertAllPass(_ results: [DiagnosticsCheck: DiagnosticsResult]) throws {
        let allPassing = DiagnosticsCheck.allCases.allSatisfy { results[$0] == .pass }
        if !allPassing {
            throw DriverError.rowsFailed(results)
        }
    }
}
