import XCTest

/// Flow: rename a profile via the row's edit-info button → Edit Info sheet.
/// The profile is seeded via `-SeedProfile` so the test doesn't drive the add
/// flow (whose SecureField triggers an iOS "Save Password?" dialog).
final class RenameSubscriptionFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testRenamePersists() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests", "-ResetState", "-SeedProfile", "My Servers"]
        app.launch()

        app.tabBars.buttons["Subscriptions"].tap()
        XCTAssertTrue(app.staticTexts["My Servers"].waitForExistence(timeout: 5))

        // The always-visible edit-info button opens the rename sheet.
        let editInfo = app.buttons["subscriptions.row.editInfoButton"]
        XCTAssertTrue(editInfo.waitForExistence(timeout: 5))
        editInfo.tap()

        let nameField = app.textFields["subscriptions.editInfo.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        // Cursor to the end of the text, clear it, type the new name.
        nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let existing = (nameField.value as? String) ?? ""
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        nameField.typeText("SG Servers")
        app.buttons["subscriptions.editInfo.saveButton"].tap()

        XCTAssertTrue(app.staticTexts["SG Servers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["My Servers"].exists)
    }
}
