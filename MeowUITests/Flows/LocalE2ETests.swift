import MeowModels
import XCTest

/// Local XCUITest layer for the M1.5 5-check gate, runnable on any
/// Mac with an iOS 26 simulator. Ladder position: *Option 2* on the
/// contract-smoke ↔ full-vphone-gate continuum. It drives the `-UITests`
/// seeder (bundled fixture YAML, auto-selected profile, pre-approved
/// NETunnelProviderManager) so that the toggle goes live and the
/// tunnel can actually start. It is *still not* the PASS-asserting
/// nightly — that's `E2E5CheckGateTests` + `Support/VPhone.swift`
/// (TEST_STRATEGY v1.2 §7), which needs a Tart VM, a real proxy, and
/// a live C2 endpoint. The only checks this bundle asserts PASS for
/// are the ones that don't depend on an outbound path: `TUN_EXISTS`
/// (extension running) and `MEM_OK` (extension under the appex cap).
///
/// What this bundle does:
///
/// 1. **Anchor wiring** — every `VPhone.HomeScreen.AccessibilityID`
///    identifier the T4.2 spec promises is actually queryable at
///    launch, so a rename on the View side can't silently break the
///    nightly driver.
/// 2. **State-badge vocabulary** — `home.badge.state`'s text parses
///    via `VPhone.HomeScreen.ConnectionState(rawValue:)`. Any drift
///    from the frozen lowercase-ASCII vocabulary (PRD §4.3) fails
///    here, not two hours into a nightly run.
/// 3. **Toggle liveness** — with the `-UITests` seeder selecting a
///    DIRECT-only fixture profile, `home.toggle.vpn` enables on
///    launch. Tapping it must move the badge to `connecting` within
///    5s. We deliberately don't wait for `connected` — locally there
///    is no remote proxy to tunnel to, but the extension itself
///    comes up and that's what the next test pins on.
/// 4. **Diagnostics contract + extension liveness** — navigating via
///    `home.nav.diagnostics` exposes the 5 PRD §4.4 rows with correct
///    `diagnostics.row.<KEY>` identifiers and parseable labels. Post-
///    connect, `TUN_EXISTS: PASS` and `MEM_OK: PASS` are asserted
///    (the extension is up and under the 50MB cap). `DNS_OK`,
///    `TCP_PROXY_OK`, and `HTTP_204_OK` are allowed to FAIL — those
///    need a real outbound, which local sims don't have.
///
/// Why not full PASS: the user's Mac has no Tart fixture, no
/// wireguard-go endpoint, no C2 server — all the things the three
/// outbound checks probe. The nightly vphone run asserts PASS on all
/// 5; this bundle asserts PASS only on the subset that stays true in
/// an outbound-less environment, plus pins the contract the nightly
/// relies on.
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

    // MARK: - (3) Toggle liveness

    /// Tapping the VPN toggle from a disconnected state must move the
    /// badge to `connecting` within 5s. The `-UITests` seeder (see
    /// `UITestsSeeder`) installs a DIRECT-only Clash profile and
    /// `VpnManager.refresh()` pre-approves the NETunnelProviderManager,
    /// so the toggle is enabled on launch and the tunnel can start.
    /// We don't wait for `connected` — on a local sim there is no
    /// remote proxy to tunnel to. The bookkeeping we *do* care about
    /// (the extension is running, it's under its memory cap) moves to
    /// `testPostConnectDiagnosticsReportTunAndMemPass`.
    func testToggleMovesBadgeToConnecting() throws {
        let app = launchHome()

        let badge = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge,
        ]
        let toggle = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.vpnToggle,
        ]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        waitForDisconnected(badge: badge, app: app, timeout: 10)

        XCTAssertTrue(
            toggle.isEnabled,
            "home.toggle.vpn is disabled — `-UITests` seeder should have installed a selected profile. " +
            "Check UITestsSeeder + bundled UITestsFixtureProfile.yaml."
        )
        toggle.tap()
        app.activate() // flush any pending NE consent interruption

        let reachedConnecting = expectation(for: NSPredicate(format: "label == %@",
                                                             VPhone.HomeScreen.ConnectionState.connecting.rawValue),
                                            evaluatedWith: badge)
        wait(for: [reachedConnecting], timeout: 5)
    }

    /// With the tunnel up, the diagnostics panel should report
    /// `TUN_EXISTS: PASS` (extension is running) and `MEM_OK: PASS`
    /// (extension is under the 50MB appex cap). The other three checks
    /// need a real outbound path and are expected to `FAIL(...)` on a
    /// local sim — we don't assert on them.
    ///
    /// One retry budget: first-ever launch on a fresh sim image may
    /// stall on the NE consent flow; the interruption monitor + a
    /// single relaunch gets past it. Beyond that, we surface a real
    /// failure rather than paper over flakiness.
    func testPostConnectDiagnosticsReportTunAndMemPass() throws {
        try runPostConnectDiagnostics(attempt: 1, maxAttempts: 2)
    }

    private func runPostConnectDiagnostics(attempt: Int, maxAttempts: Int) throws {
        let app = launchHome()

        let badge = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge
        ]
        let toggle = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.vpnToggle
        ]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        waitForDisconnected(badge: badge, app: app, timeout: 10)

        guard toggle.isEnabled else {
            if attempt < maxAttempts {
                app.terminate()
                try runPostConnectDiagnostics(attempt: attempt + 1, maxAttempts: maxAttempts)
                return
            }
            XCTFail("home.toggle.vpn stayed disabled across \(maxAttempts) attempts")
            return
        }

        toggle.tap()
        app.activate() // flush consent interruption, if any

        // Wait for the tunnel to leave `disconnected`. We accept either
        // `connecting` or `connected` — the point of this test is that the
        // extension is up, not that the status machine passed through a
        // specific state.
        let leftDisconnected = expectation(for: NSPredicate(format: "label != %@",
                                                            VPhone.HomeScreen.ConnectionState.disconnected.rawValue),
                                           evaluatedWith: badge)
        let leftResult = XCTWaiter().wait(for: [leftDisconnected], timeout: 10)
        guard leftResult == .completed else {
            if attempt < maxAttempts {
                app.terminate()
                try runPostConnectDiagnostics(attempt: attempt + 1, maxAttempts: maxAttempts)
                return
            }
            XCTFail("tunnel did not leave disconnected after \(maxAttempts) attempts")
            return
        }

        let nav = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.navDiagnostics
        ]
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        nav.tap()

        let runButton = app.descendants(matching: .any)["diagnostics.button.run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        XCTAssertTrue(runButton.isHittable)
        runButton.tap()

        let deadline = Date().addingTimeInterval(20)
        var lastResults: [DiagnosticsCheck: DiagnosticsResult] = [:]
        while Date() < deadline {
            let dump = DiagnosticsCheck.allCases.compactMap { check -> String? in
                let row = app.descendants(matching: .any)["diagnostics.row.\(check.rawValue)"]
                return row.exists ? row.label : nil
            }.joined(separator: "\n")

            if let parsed = try? DiagnosticsLabelParser.parse(dump) {
                lastResults = parsed
                if parsed[.tunExists] == .pass && parsed[.memOk] == .pass {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let snapshot = DiagnosticsCheck.allCases.map { check in
            "\(check.rawValue)=\(lastResults[check].map(String.init(describing:)) ?? "<absent>")"
        }.joined(separator: ", ")
        XCTFail("TUN_EXISTS + MEM_OK did not both reach PASS within 20s — last seen: \(snapshot)")
    }

    private func waitForDisconnected(badge: XCUIElement, app: XCUIApplication, timeout: TimeInterval) {
        let isDisconnected = NSPredicate(format: "label == %@",
                                         VPhone.HomeScreen.ConnectionState.disconnected.rawValue)
        let e = expectation(for: isDisconnected, evaluatedWith: badge)
        if XCTWaiter().wait(for: [e], timeout: timeout) == .completed { return }
        // Give interruption monitor a chance to dismiss NE consent, then
        // accept the current label — the individual tests will assert their
        // own preconditions.
        app.activate()
    }

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
