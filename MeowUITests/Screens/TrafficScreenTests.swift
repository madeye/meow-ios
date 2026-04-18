import XCTest

final class TrafficScreenTests: XCTestCase {
    func testEmptyStateShowsOnFreshInstall() {
        let meow = MeowApp(resetState: true)
        meow.launch()
        meow.trafficTab.tap()
        let emptyState = meow.app.descendants(matching: .any)["traffic.emptyState"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
    }
}
