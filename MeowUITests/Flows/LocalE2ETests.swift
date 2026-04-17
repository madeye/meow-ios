import MeowModels
import XCTest

/// Local XCUITest layer for the M1.5 5-check gate, runnable on any
/// Mac with an iOS 26 simulator. Ladder position: *Option 2 (β)* on
/// the contract-smoke ↔ full-vphone-gate continuum — seeder pipeline
/// + NE error-surface UX, but *not* a real `.connecting → .connected`
/// transition. That lives in the nightly vphone gate
/// (`E2E5CheckGateTests` + `Support/VPhone.swift`, TEST_STRATEGY v1.2
/// §7), which needs a Tart VM, a real proxy, and a live C2 endpoint.
///
/// Why this bundle doesn't assert connected: `NETunnelProviderManager`
/// operations fail on the iOS 26 simulator with
/// `NEVPNErrorDomain Code=5 ("IPC failed")` — the sim has no
/// `nesessionmanager` daemon to service the IPC. So
/// `saveToPreferences` / `startVPNTunnel` never complete, and no
/// amount of seeder wiring can get the badge to `connecting`. That
/// failure mode is the one we lean into: we pin the UX contract that
/// an NE error bubbles up to the user instead of vanishing.
///
/// What this bundle pins:
///
/// 1. **Anchor wiring** — every `VPhone.HomeScreen.AccessibilityID`
///    identifier the T4.2 spec promises is actually queryable at
///    launch, so a rename on the View side can't silently break the
///    nightly driver.
/// 2. **State-badge vocabulary** — `home.badge.state`'s text parses
///    via `VPhone.HomeScreen.ConnectionState(rawValue:)`. Any drift
///    from the frozen lowercase-ASCII vocabulary (PRD §4.3) fails
///    here, not two hours into a nightly run.
/// 3. **Seeder + NE error surface** — with the `-UITests` seeder
///    selecting a DIRECT-only fixture profile, `home.toggle.vpn` is
///    enabled on launch (which by itself proves the seeder ran end to
///    end). Tapping the toggle triggers `VpnManager.connect()`, which
///    on the sim fails with an `NEVPNError`. The test asserts:
///    (a) `home.badge.state` stays `disconnected`,
///    (b) `home.error` renders a machine-parseable
///        `<Domain>(<Code>): <message>` label pointing at
///        `NEVPNErrorDomain` with an integer code.
///    Loose assertions ("any non-empty error") would let a rename of
///    `VpnManager.lastError` or a string-interpolation typo slip
///    through — the tight domain+code pin catches that.
/// 4. **Diagnostics contract** — navigating via `home.nav.diagnostics`
///    exposes the 5 PRD §4.4 rows with correct `diagnostics.row.<KEY>`
///    identifiers, and the `Run Diagnostics` button updates each row
///    within a bounded timeout. We assert only that each row parses
///    via `DiagnosticsLabelParser`; the actual PASS/FAIL result is
///    irrelevant here because the extension never runs on the sim.
///
/// What this bundle does **not** do (intentionally):
/// - assert `.connecting` / `.connected` — sim NE can't reach either;
/// - assert `TUN_EXISTS: PASS` / `MEM_OK: PASS` — needs the extension
///   to be running, which needs NE IPC, which the sim doesn't have.
/// Both live in the nightly vphone gate.
///
/// Running: `xcodebuild test -scheme meow-ios
/// -destination 'platform=iOS Simulator,name=iPhone 17'
/// -only-testing:MeowUITests/LocalE2ETests`.
@MainActor
final class LocalE2ETests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Belt-and-braces fallback for the NE consent dialog. `VpnManager.refresh()`
    /// calls `saveToPreferences` on launch, which on a brand-new sim image
    /// triggers a system consent sheet ("meow Would Like to Add VPN
    /// Configurations"). Programmatic save is enough on most images because
    /// the manager is reused across relaunches, but on a fresh image we need
    /// a UI path too. The monitor must be followed by an interaction with
    /// the app — XCTest only drains interruption handlers on the next
    /// `app.*` call.
    private func installNEConsentMonitor(on app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "NE consent") { alert in
            for label in ["Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    // MARK: - (1) Anchor wiring

    /// Every identifier declared in `VPhone.HomeScreen.AccessibilityID`
    /// must resolve to a queryable element on launch. The dynamic
    /// `group(_:)` / `proxy(group:proxy:)` IDs are excluded — they only
    /// render once the engine has a live `/proxies` response, which
    /// this bundle does not set up.
    func testHomeAnchorsExist() {
        let app = launchHome()

        let anchors = [
            VPhone.HomeScreen.AccessibilityID.vpnToggle,
            VPhone.HomeScreen.AccessibilityID.stateBadge,
            VPhone.HomeScreen.AccessibilityID.profileName,
            VPhone.HomeScreen.AccessibilityID.navDiagnostics,
        ]

        for id in anchors {
            let element = app.descendants(matching: .any)[id]
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "T4.2 anchor missing: \(id)",
            )
        }
    }

    // MARK: - (2) State-badge vocabulary

    func testStateBadgeParsesAsConnectionState() {
        let app = launchHome()

        let badge = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge,
        ]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))

        let raw = badge.label
        XCTAssertNotNil(
            VPhone.HomeScreen.ConnectionState(rawValue: raw),
            "home.badge.state = \"\(raw)\", expected one of " +
                "\(VPhone.HomeScreen.ConnectionState.allCases.map(\.rawValue))",
        )
    }

    // MARK: - (3) Seeder + NE error surface

    /// End-to-end pin for Option 2 (β): seeder runs → toggle enables →
    /// tap produces a tightly-typed NE error surface. Three assertions,
    /// all of which must hold:
    ///
    /// 1. **Seeder ran.** `home.toggle.vpn.isEnabled == true` at launch
    ///    — only possible if `UITestsSeeder` inserted a selected Profile
    ///    into SwiftData on the `-UITests` path.
    /// 2. **Badge stays `disconnected`.** On sim NE IPC fails, so the
    ///    UI must not lie by advancing to `connecting`. Loose check
    ///    ("not connected") would allow a `connecting` → `disconnected`
    ///    flicker to slip through.
    /// 3. **`home.error` is populated and parseable.** Label format is
    ///    `<Domain>(<Code>): <message>`. On iOS 26 sim `Domain` is
    ///    exactly `NEVPNErrorDomain` and `Code` is an integer. A
    ///    rename in `VpnManager.VpnManagerError.label` breaks this,
    ///    which is the intent — loose "label != empty" would hide
    ///    that regression.
    ///
    /// This doesn't prove the real-device NE path works. That's what
    /// the nightly vphone gate is for. What it *does* prove: if the
    /// NE stack surfaces an error, the user sees a structured one
    /// (not a silent no-op).
    func testTapToggleSurfacesNEError() throws {
        let app = launchHome()

        let badge = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge,
        ]
        let toggle = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.vpnToggle,
        ]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        XCTAssertEqual(
            badge.label,
            VPhone.HomeScreen.ConnectionState.disconnected.rawValue,
            "Expected home.badge.state to read `disconnected` on a cold launch"
        )

        XCTAssertTrue(
            toggle.isEnabled,
            "home.toggle.vpn is disabled — `-UITests` seeder should have installed a selected profile. " +
            "Check UITestsSeeder + bundled UITestsFixtureProfile.yaml."
        )
        toggle.tap()
        app.activate() // flush any pending NE consent interruption

        let errorLabel = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.errorMessage
        ]
        XCTAssertTrue(
            errorLabel.waitForExistence(timeout: 5),
            "home.error did not appear after tapping toggle — VpnManager.lastError not surfaced"
        )

        // Pin #1: badge didn't lie about progress.
        XCTAssertEqual(
            badge.label,
            VPhone.HomeScreen.ConnectionState.disconnected.rawValue,
            "home.badge.state advanced past `disconnected` despite NE error — " +
            "UX is reporting progress that isn't happening"
        )

        // Pin #2: error label is structured — `<Domain>(<Code>): <message>`.
        let raw = errorLabel.label
        let match = try XCTUnwrap(
            Self.errorLabelRegex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
            "home.error = \"\(raw)\", expected `<Domain>(<Code>): <message>` per VpnManagerError.label"
        )
        let domain = (raw as NSString).substring(with: match.range(at: 1))
        let codeStr = (raw as NSString).substring(with: match.range(at: 2))
        XCTAssertEqual(
            domain, "NEVPNErrorDomain",
            "home.error domain = \"\(domain)\" — expected `NEVPNErrorDomain` (seeing a non-NE error " +
            "here would mean the failure is upstream of the NE call, which is a real regression)"
        )
        XCTAssertNotNil(Int(codeStr), "home.error code = \"\(codeStr)\", expected integer")
    }

    /// `<Domain>(<Code>): <message>` — matches `VpnManagerError.label`.
    /// Domain is any non-paren/non-colon run so a rename like
    /// `NEVPNError` (without `Domain`) still matches structurally; the
    /// separate equality check on `NEVPNErrorDomain` pins the exact name.
    private static let errorLabelRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^([^(]+)\((-?\d+)\):\s"#)
    }()

    // MARK: - (4) Diagnostics panel contract

    func testDiagnosticsPanelExposesFiveRows() {
        let app = launchHome()

        let nav = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.navDiagnostics,
        ]
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        nav.tap()

        for check in DiagnosticsCheck.allCases {
            let row = app.descendants(matching: .any)["diagnostics.row.\(check.rawValue)"]
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "diagnostics.row.\(check.rawValue) missing — T2.6 contract drift",
            )
        }
    }

    /// Tap `Run Diagnostics` and verify each of the 5 rows parses via
    /// `DiagnosticsLabelParser`. We don't assert the result (PASS vs
    /// FAIL) — on a local sim the extension isn't running, so every
    /// check will FAIL. The contract we're pinning is:
    /// - the row text follows PRD §4.4's `CHECK_NAME: PASS|FAIL(reason)`
    ///   shape
    /// - it refreshes within a bounded timeout (liveness, not latency)
    func testRunButtonRefreshesRowsWithinTimeout() {
        let app = launchHome()

        let nav = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.navDiagnostics,
        ]
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        nav.tap()

        let runButton = app.descendants(matching: .any)["diagnostics.button.run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        XCTAssertTrue(runButton.isHittable, "Run Diagnostics button not hittable")
        runButton.tap()

        // Poll the 5 rows until they all parse. Budget: 20s — matches
        // the nightly `DiagnosticsScreen.readResults(timeout:)` default
        // so the two layers agree on "unresponsive."
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let dump = DiagnosticsCheck.allCases.compactMap { check -> String? in
                let row = app.descendants(matching: .any)["diagnostics.row.\(check.rawValue)"]
                return row.exists ? row.label : nil
            }.joined(separator: "\n")

            if (try? DiagnosticsLabelParser.parse(dump)) != nil { return }
            Thread.sleep(forTimeInterval: 0.25)
        }

        XCTFail("5 diagnostics rows did not render parseable PRD §4.4 labels within 20s")
    }

    // MARK: - Helpers

    private func launchHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-UITests", "-ResetState"])
        installNEConsentMonitor(on: app)
        app.launch()
        // Nudge the app so XCTest drains any pending interruption handler.
        // The monitor only fires on the *next* app interaction.
        _ = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge
        ].waitForExistence(timeout: 5)
        return app
    }
}
