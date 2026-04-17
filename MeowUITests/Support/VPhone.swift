import Foundation

/// Swift wrapper around the `vm/vphone.sock` protocol exposed by
/// [vphone-cli](https://github.com/Lakr233/vphone-cli). Used from
/// `MeowUITests/Flows/E2E5CheckGateTests.swift` (PRD §7) to drive the
/// virtual iPhone in the nightly E2E pipeline.
///
/// Status: STUB. Blocked on Tart base image (T-infra) and the in-app
/// diagnostics panel (T3.6) that surfaces per-check pass/fail.
///
/// Design notes:
/// - Methods are named like page-object operations (`home.tapConnect()`)
///   rather than raw coordinates. When the iOS layout changes, only
///   this file needs updating — not every test.
/// - Screenshots return `Data` (PNG); OCR / pixel-diff is done in tests
///   or in a small Python helper script (`scripts/assert-ocr.py`).
/// - All writes over the socket are strictly typed; any unexpected
///   response fails the current test with a descriptive error.
struct VPhone {
    let socketPath: String

    init(socketPath: String = "/tmp/vphone.sock") {
        self.socketPath = socketPath
    }

    // MARK: Automation primitives (raw socket ops)

    func tap(x: Int, y: Int) throws { fatalError("T-infra: implement when Tart image is baked") }
    func swipe(from: (Int, Int), to: (Int, Int), durationMs: Int = 200) throws { fatalError("T-infra") }
    func keys(_ text: String) throws { fatalError("T-infra") }
    func clipboardSet(_ text: String) throws { fatalError("T-infra") }
    func clipboardGet() throws -> String { fatalError("T-infra") }
    func screenshot() throws -> Data { fatalError("T-infra") }
    func homeButton() throws { fatalError("T-infra") }
    func openURL(_ url: URL) throws { fatalError("T-infra") }

    // MARK: Page objects (tests call these, not the primitives above)

    var home: HomeScreen { HomeScreen(phone: self) }
    var diagnostics: DiagnosticsScreen { DiagnosticsScreen(phone: self) }

    struct HomeScreen {
        let phone: VPhone
        func tapConnect() throws { try phone.tap(x: 200, y: 420) }         // TODO: real coords post-T3.7
        func waitForConnected(timeout: TimeInterval = 10) throws { fatalError("T3.7") }
        func screenshot() throws -> Data { try phone.screenshot() }
    }

    struct DiagnosticsScreen {
        let phone: VPhone
        func navigate() throws { fatalError("T3.6") }                      // debug-only tab
        func tapRun() throws { fatalError("T3.6") }
        /// Returns the 5 check rows. Each is (name, PASS/FAIL, optional detail).
        func readResults(timeout: TimeInterval = 20) throws -> [(String, Bool, String?)] { fatalError("T3.6") }
    }
}
