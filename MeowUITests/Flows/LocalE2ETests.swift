import XCTest
import MeowModels

/// Contract-smoke layer for the M1.5 5-check gate, runnable on any Mac
/// with an iOS 26 simulator. This bundle *is not* the PASS-asserting
/// gate — that's the nightly vphone-cli path
/// (`MeowUITests/Flows/E2E5CheckGateTests` + `Support/VPhone.swift`,
/// TEST_STRATEGY v1.2 §7) which needs a Tart VM, a real proxy, and
/// extension entitlements. Those assertions belong there.
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
/// 3. **Toggle liveness** — tapping `home.toggle.vpn` moves the badge
///    to `connecting`. We deliberately don't wait for `connected` —
///    that needs a real proxy; local sims have no tunnel target.
/// 4. **Diagnostics panel contract** — navigating via
///    `home.nav.diagnostics` exposes the 5 PRD §4.4 rows with correct
///    `diagnostics.row.<KEY>` identifiers, and the `Run Diagnostics`
///    button updates each row within a bounded timeout. We assert
///    only that each row parses via `DiagnosticsLabelParser` — the
///    result (PASS or FAIL) is irrelevant here because there's no
///    real extension backing the checks on a local sim.
///
/// Why contract-smoke and not PASS-asserting: the user's Mac has no
/// Tart fixture, no wireguard-go endpoint, no C2 server — all the
/// things the 5 checks actually probe. Asserting PASS locally would
/// either force every contributor to stand up that infra or make the
/// tests lie. The nightly vphone run is the gate; this is the
/// compile-time-adjacent guard that the contract the gate relies on
/// still exists.
///
/// Running: `xcodebuild test -scheme meow-ios
/// -destination 'platform=iOS Simulator,name=iPhone 17'
/// -only-testing:MeowUITests/LocalE2ETests`.
final class LocalE2ETests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - (1) Anchor wiring

    /// Every identifier declared in `VPhone.HomeScreen.AccessibilityID`
    /// must resolve to a queryable element on launch. The dynamic
    /// `group(_:)` / `proxy(group:proxy:)` IDs are excluded — they only
    /// render once the engine has a live `/proxies` response, which
    /// this bundle does not set up.
    func testHomeAnchorsExist() throws {
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
                "T4.2 anchor missing: \(id)"
            )
        }
    }

    // MARK: - (2) State-badge vocabulary

    func testStateBadgeParsesAsConnectionState() throws {
        let app = launchHome()

        let badge = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge
        ]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))

        let raw = badge.label
        XCTAssertNotNil(
            VPhone.HomeScreen.ConnectionState(rawValue: raw),
            "home.badge.state = \"\(raw)\", expected one of " +
            "\(VPhone.HomeScreen.ConnectionState.allCases.map(\.rawValue))"
        )
    }

    // MARK: - (3) Toggle liveness

    /// Tapping the VPN toggle from a disconnected state must move the
    /// badge to `connecting`. We don't wait for `connected` — that
    /// would require a real proxy + extension approval, which local
    /// sims don't have. The goal here is only to prove the toggle is
    /// wired to `vpnManager.connect()` and the badge re-renders.
    func testToggleMovesBadgeToConnecting() throws {
        let app = launchHome()

        let badge = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.stateBadge
        ]
        let toggle = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.vpnToggle
        ]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // Precondition — we start disconnected. If a prior run left
        // state around, `-ResetState` in `launchHome()` should have
        // cleared it.
        XCTAssertEqual(badge.label, VPhone.HomeScreen.ConnectionState.disconnected.rawValue)

        // On a cold sim with no seeded profile, `home.toggle.vpn` is
        // `.disabled(true)` in HomeView (the button only enables when
        // a profile is selected or the tunnel is already up). That's
        // the common case for this bundle — full toggle liveness is
        // exercised in the nightly vphone path where a profile is
        // pre-seeded on the Tart image. Contract-smoke-wise, proving
        // the anchor exists + is well-typed-but-disabled is the
        // strongest statement we can honestly make locally.
        guard toggle.isEnabled else {
            throw XCTSkip(
                "home.toggle.vpn is disabled — no profile seeded on this launch. " +
                "Full toggle liveness runs in the nightly vphone gate, not here."
            )
        }
        toggle.tap()

        let reachedConnecting = expectation(for: NSPredicate(format: "label == %@",
                                                             VPhone.HomeScreen.ConnectionState.connecting.rawValue),
                                            evaluatedWith: badge)
        wait(for: [reachedConnecting], timeout: 3)
    }

    // MARK: - (4) Diagnostics panel contract

    func testDiagnosticsPanelExposesFiveRows() throws {
        let app = launchHome()

        let nav = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.navDiagnostics
        ]
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        nav.tap()

        for check in DiagnosticsCheck.allCases {
            let row = app.descendants(matching: .any)["diagnostics.row.\(check.rawValue)"]
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "diagnostics.row.\(check.rawValue) missing — T2.6 contract drift"
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
    func testRunButtonRefreshesRowsWithinTimeout() throws {
        let app = launchHome()

        let nav = app.descendants(matching: .any)[
            VPhone.HomeScreen.AccessibilityID.navDiagnostics
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
        app.launch()
        return app
    }
}
