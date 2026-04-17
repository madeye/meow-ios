import XCTest

final class HomeScreenTests: XCTestCase {
    func testTrafficTilesUpdateWithInjectedSnapshots() throws {
        throw XCTSkip("blocked on T5.2")
        // with `-UITests` active, posting a fake TrafficSnapshot must update the UI within 1s
    }

    func testRouteModePickerPersists() throws {
        throw XCTSkip("blocked on T5.2")
        // pick Global → relaunch → picker still shows Global
    }

    func testProxyGroupSectionOnlyVisibleWhenConnected() throws {
        throw XCTSkip("blocked on T5.2")
    }

    func testConnectionsNavLinkOnlyVisibleWhenConnected() throws {
        throw XCTSkip("blocked on T5.2 + T5.5")
    }
}
