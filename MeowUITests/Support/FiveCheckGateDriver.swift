import Foundation
import MeowModels

/// T4.2 navigation seam. The default implementation
/// (`FiveCheckGateDriver.defaultNavigateToDiagnostics`) taps the
/// `home.nav.diagnostics` accessibility identifier Dev wired on T4.2
/// — so once T-infra lands the vphone-cli primitives, callers get a
/// working navigation step for free. The closure is still injectable
/// for tests that need an alternative entry point (shake gesture,
/// debug menu, deep link) without editing the driver.
///
/// Mirrors the `drive(proxy:assertion:)` stub pattern in
/// `MeowIntegrationTests/ProtocolFixtures/UDPProtocolTests.swift`:
/// abstract the unknown, exercise the known.
typealias NavigateToDiagnostics = @Sendable (VPhone) throws -> Void

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
///         subscriptionDeepLink: URL(string: "meow://connect?url=\(encoded)")!
///     )
///     let results = try driver.runToResults()
///     // Caller picks whichever rows they care about:
///     XCTAssertEqual(results[.tcpProxyOk], .pass)
///
/// The default navigation closure taps the T4.2 `home.nav.diagnostics`
/// anchor; pass `navigateToDiagnostics:` explicitly only when targeting
/// an alternative entry point.
struct FiveCheckGateDriver {
    let phone: VPhone
    let subscriptionDeepLink: URL
    let navigateToDiagnostics: NavigateToDiagnostics
    var connectTimeout: TimeInterval = 10
    var diagnosticsReadTimeout: TimeInterval = 20

    /// Default navigation: tap the `home.nav.diagnostics` anchor exposed
    /// by T4.2. Most callers get this for free via `init(..., navigateToDiagnostics:)`'s
    /// default; inject a different closure only for alternative entry
    /// points (shake gesture, debug menu, deep link).
    static let defaultNavigateToDiagnostics: NavigateToDiagnostics = { phone in
        try phone.home.tapNavDiagnostics()
    }

    init(
        phone: VPhone,
        subscriptionDeepLink: URL,
        navigateToDiagnostics: @escaping NavigateToDiagnostics = FiveCheckGateDriver.defaultNavigateToDiagnostics,
        connectTimeout: TimeInterval = 10,
        diagnosticsReadTimeout: TimeInterval = 20
    ) {
        self.phone = phone
        self.subscriptionDeepLink = subscriptionDeepLink
        self.navigateToDiagnostics = navigateToDiagnostics
        self.connectTimeout = connectTimeout
        self.diagnosticsReadTimeout = diagnosticsReadTimeout
    }

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

    /// Step 3. Block until `home.badge.state` reads `connected` per the
    /// T4.2 spec — `HomeScreen.waitForConnected` polls the anchor text
    /// rather than OCR'ing a visual. If the REST external-controller
    /// path (`/configs`, `is_running == 1`) becomes preferable later,
    /// swap the impl behind this phase; the driver's caller contract
    /// is unchanged.
    func waitForRunning(timeout: TimeInterval? = nil) throws {
        let t = timeout ?? connectTimeout
        do {
            try phone.home.waitForConnected(timeout: t)
        } catch {
            throw DriverError.stillNotRunning(after: t)
        }
    }

    /// Step 4. Delegate to the injected closure (defaults to tapping
    /// `home.nav.diagnostics`).
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
