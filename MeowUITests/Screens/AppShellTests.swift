import XCTest

final class AppShellTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testGlobalVpnTogglePersistsAcrossPrimaryTabs() {
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.home.vpnToggle.waitForExistence(timeout: 5))

        meow.subscriptionsTab.tap()
        XCTAssertTrue(meow.home.vpnToggle.exists)

        meow.proxyGroupsTab.tap()
        XCTAssertTrue(meow.home.vpnToggle.exists)

        meow.trafficTab.tap()
        XCTAssertTrue(meow.home.vpnToggle.exists)
    }

    func testSubscriptionsIsDefaultHomeTab() {
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.app.navigationBars["Subscriptions"].waitForExistence(timeout: 5))
        XCTAssertFalse(meow.app.tabBars.buttons["Home"].exists)
    }

    func testProxyGroupsIsTopLevelTab() {
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.proxyGroupsTab.waitForExistence(timeout: 5))
        meow.proxyGroupsTab.tap()
        XCTAssertTrue(meow.app.navigationBars["Proxy Groups"].waitForExistence(timeout: 5))
    }
}
