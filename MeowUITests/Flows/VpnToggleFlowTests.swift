import XCTest

/// Flow: VPN connect/disconnect from Home. Uses a fake VPN manager (enabled
/// via `-UITests`) so the test does not require the real NetworkExtension.
final class VpnToggleFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testConnectDisconnectHappyPath() throws {
        throw XCTSkip("blocked on T5.2 HomeView")
        // launch with a pre-selected profile
        // tap VPN toggle → status goes idle → connecting → connected within 5s
        // tap again → stopping → idle
    }

    func testFirstLaunchPermissionPrompt() throws {
        throw XCTSkip("requires interruption monitor for NEVPNManager consent")
        // addUIInterruptionMonitor for VPN consent alert → tap Allow
        // verify connect proceeds afterwards
    }

    func testStatusSurvivesTabSwitch() throws {
        throw XCTSkip("blocked on T5.1 + T5.2")
        // connect, navigate to Settings, return to Home — still connected
    }

    func testConnectWithNoProfileShowsError() throws {
        throw XCTSkip("blocked on T5.2")
        // no profile selected → toggle shows error banner with specific text
    }
}
