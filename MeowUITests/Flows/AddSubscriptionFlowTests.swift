import XCTest

/// Flow: user launches the app, adds a subscription, sees it in the list.
/// Also covers validation (empty URL, malformed URL) and delete-via-swipe.
final class AddSubscriptionFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAddSubscriptionHappyPath() throws {
        throw XCTSkip("blocked on T5.3 SubscriptionsView")
        // let meow = MeowApp()
        // meow.launch()
        // meow.subscriptionsTab.tap()
        // meow.subscriptions.addButton.tap()
        // meow.subscriptions.nameField.tap(); meow.subscriptions.nameField.typeText("My Sub")
        // meow.subscriptions.urlField.tap(); meow.subscriptions.urlField.typeText("https://example.com/sub")
        // meow.subscriptions.submitButton.tap()
        // XCTAssertTrue(meow.subscriptions.row(named: "My Sub").waitForExistence(timeout: 3))
    }

    func testEmptyURLShowsValidationError() throws {
        throw XCTSkip("blocked on T5.3")
        // submit with empty URL → alert with specific message
    }

    func testSwipeToDeleteRemovesRow() throws {
        throw XCTSkip("blocked on T5.3")
        // seed one profile via -UITests, swipe to delete, row disappears
    }

    func testTapRowNavigatesToYamlEditor() throws {
        throw XCTSkip("blocked on T5.3 + T5.9")
        // tap row → YAML editor screen with file content visible
    }
}
