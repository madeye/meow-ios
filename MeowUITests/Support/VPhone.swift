import Foundation
import MeowModels

/// Swift wrapper around the `vm/vphone.sock` protocol exposed by
/// [vphone-cli](https://github.com/Lakr233/vphone-cli). Used from
/// `MeowUITests/Flows/E2E5CheckGateTests.swift` (TEST_STRATEGY §7) to
/// drive the virtual iPhone in the nightly E2E pipeline.
///
/// Status: STUB. Blocked on Tart base image (T-infra) and the Debug
/// Diagnostics Panel (T2.6, PRD §4.4) that surfaces per-check pass/fail.
///
/// Design notes:
/// - Methods are named like page-object operations (`home.tapConnect()`)
///   rather than raw coordinates. When the iOS layout changes, only
///   this file needs updating — not every test.
/// - Screenshots return `Data` (PNG); OCR / pixel-diff is done in tests
///   or in a small Python helper script (`scripts/assert-ocr.py`).
/// - The diagnostics page object consumes the PRD §4.4 frozen label
///   format — any drift in the app's output format fails the parser
///   below rather than silently producing false PASSes.
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
        func tapConnect() throws { try phone.tap(x: 200, y: 420) }
        func waitForConnected(timeout: TimeInterval = 10) throws { fatalError("T3.7") }
        func screenshot() throws -> Data { try phone.screenshot() }
    }

    struct DiagnosticsScreen {
        let phone: VPhone
        func navigate() throws { fatalError("T2.6") }
        func tapRun() throws { fatalError("T2.6") }

        /// Returns one `Result` per PRD §4.4 check, in the fixed display order.
        /// Parser enforces the frozen `CHECK_NAME: PASS|FAIL(reason)` format.
        func readResults(timeout: TimeInterval = 20) throws -> [DiagnosticsCheck: DiagnosticsResult] {
            fatalError("T2.6")
        }
    }
}

// PRD §4.4 frozen contract — `DiagnosticsCheck`, `DiagnosticsResult`,
// and `DiagnosticsLabelParser` live in `MeowShared/MeowModels` so the
// app's panel (T2.6), this UI-test bundle, and the unit tests all
// consume identical label keys. If Dev renames any case, this file
// fails to compile — that is the point.
