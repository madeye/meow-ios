import Foundation
import MeowModels

/// Swift wrapper around the `vm/vphone.sock` protocol exposed by
/// [vphone-cli](https://github.com/Lakr233/vphone-cli). Used from
/// `MeowUITests/Flows/E2E5CheckGateTests.swift` (TEST_STRATEGY §7) to
/// drive the virtual iPhone in the nightly E2E pipeline.
///
/// Status: STUB. Primitives still `fatalError("T-infra")` pending the
/// Tart base image + vphone-cli wire-up. The page objects below are
/// already wired against the T4.2 accessibility-identifier spec (see
/// `HomeScreen.AccessibilityID`) so that when T-infra lands, only the
/// primitive bodies need filling in — not the page objects or the
/// `FiveCheckGateDriver` state machine.
///
/// Design notes:
/// - Methods are named like page-object operations (`home.tapConnect()`)
///   rather than raw coordinates. When the iOS layout changes, the
///   driver and the tests don't move; only this file (or T4.2 anchors)
///   do.
/// - T4.2 exposes a stable set of `accessibilityIdentifier`s on the
///   Home Screen. The vphone-cli protocol surfaces them via
///   `tap(accessibilityId:)` and `text(accessibilityId:)` rather than
///   OCR, so the VPN-up precondition in the 5-check gate is parseable
///   against exact strings (`ConnectionState.rawValue`) instead of
///   screenshot pixels.
/// - `screenshot()` remains for cases OCR is actually the right tool
///   (e.g. the diagnostics panel, until T2.6's accessibility ids land).
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
    func tap(accessibilityId: String) throws { fatalError("T-infra") }
    func text(accessibilityId: String) throws -> String { fatalError("T-infra") }
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

        /// T4.2 Home Screen accessibility-identifier spec (landed in
        /// `ac4c433`). Literalises the names Dev wired on the `View`s —
        /// any rename here or there is a compile-time / test-time
        /// break, which is the point. The `group` / `proxy` builders
        /// accept the raw display name the Mihomo config emits and
        /// apply `String.identifierSlug` (shared via `MeowModels`)
        /// internally, so callers can pass `"🇺🇸 US Nodes"` and land
        /// on `home.group.us-nodes` without hand-rolling the slug.
        enum AccessibilityID {
            static let vpnToggle = "home.toggle.vpn"
            static let stateBadge = "home.badge.state"
            static let profileName = "home.profile.name"
            static let navDiagnostics = "home.nav.diagnostics"
            static func group(_ groupName: String) -> String {
                "home.group.\(groupName.identifierSlug)"
            }
            static func proxy(group groupName: String, proxy proxyName: String) -> String {
                "home.proxy.\(groupName.identifierSlug).\(proxyName.identifierSlug)"
            }
        }

        /// Parseable VPN state per T4.2: `home.badge.state`'s text is
        /// guaranteed lowercase ASCII and ∈ these four strings. This
        /// is the signal the 5-check gate driver polls on, not an OCR
        /// of the visual badge.
        enum ConnectionState: String, CaseIterable {
            case disconnected
            case connecting
            case connected
            case disconnecting
        }

        func tapConnect() throws {
            try phone.tap(accessibilityId: AccessibilityID.vpnToggle)
        }

        /// Read the current `home.badge.state` text and parse it. Throws
        /// `VPhoneError.unexpectedState` if the label drifts outside
        /// the T4.2 spec (caught early in CI so prod regressions don't
        /// pass silently).
        func stateBadge() throws -> ConnectionState {
            let raw = try phone.text(accessibilityId: AccessibilityID.stateBadge)
            guard let state = ConnectionState(rawValue: raw) else {
                throw VPhoneError.unexpectedStateBadgeText(raw)
            }
            return state
        }

        /// Poll `stateBadge()` until it reads `.connected` or `timeout`
        /// elapses. Sampling rate 4 Hz — the cold-connect budget is
        /// 5 s (TEST_STRATEGY §6.2), so 20 samples is plenty.
        func waitForConnected(timeout: TimeInterval = 10) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if try stateBadge() == .connected { return }
                Thread.sleep(forTimeInterval: 0.25)
            }
            throw VPhoneError.timedOutWaitingForState(.connected, after: timeout)
        }

        func tapNavDiagnostics() throws {
            try phone.tap(accessibilityId: AccessibilityID.navDiagnostics)
        }

        func profileName() throws -> String {
            try phone.text(accessibilityId: AccessibilityID.profileName)
        }

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

enum VPhoneError: Error, CustomStringConvertible {
    case unexpectedStateBadgeText(String)
    case timedOutWaitingForState(VPhone.HomeScreen.ConnectionState, after: TimeInterval)

    var description: String {
        switch self {
        case .unexpectedStateBadgeText(let raw):
            let expected = VPhone.HomeScreen.ConnectionState.allCases.map(\.rawValue).joined(separator: "|")
            return "home.badge.state = \"\(raw)\", expected one of {\(expected)} (T4.2 spec)"
        case .timedOutWaitingForState(let target, let t):
            return "home.badge.state never reached \"\(target.rawValue)\" within \(t)s"
        }
    }
}

// PRD §4.4 frozen contract — `DiagnosticsCheck`, `DiagnosticsResult`,
// and `DiagnosticsLabelParser` live in `MeowShared/MeowModels` so the
// app's panel (T2.6), this UI-test bundle, and the unit tests all
// consume identical label keys. If Dev renames any case, this file
// fails to compile — that is the point.
