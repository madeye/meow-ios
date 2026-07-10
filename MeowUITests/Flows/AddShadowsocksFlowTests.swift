import XCTest

/// Flow: add a Shadowsocks server manually and via a pasted `ss://` link.
/// The QR-scan path feeds the scanned payload through the same parse+apply
/// code the link field uses — the camera itself can't run on Simulator.
final class AddShadowsocksFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openSheet(_ meow: MeowApp) {
        meow.subscriptionsTab.tap()
        let addMenu = meow.app.buttons["subscriptions.toolbar.add"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.tap()
        let item = meow.app.buttons["subscriptions.toolbar.addShadowsocks"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(meow.app.navigationBars["Add Shadowsocks"].waitForExistence(timeout: 5))
    }

    func testManualEntryCreatesLocalProfile() {
        let meow = MeowApp()
        meow.launch()
        openSheet(meow)

        let app = meow.app
        let server = app.textFields["ssAdd.serverField"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        server.typeText("node.example.com")
        let port = app.textFields["ssAdd.portField"]
        port.tap()
        port.typeText("8388")
        let password = app.secureTextFields["ssAdd.passwordField"]
        password.tap()
        password.typeText("hunter22")

        let add = app.buttons["ssAdd.addButton"]
        XCTAssertTrue(add.isEnabled)
        add.tap()

        // Saving renders the template profile and engine-validates it before
        // the sheet dismisses; the generated profile then shows in the list.
        XCTAssertTrue(app.staticTexts["My Servers"].waitForExistence(timeout: 10))
    }

    func testLinkFillPopulatesForm() {
        let meow = MeowApp()
        meow.launch()
        openSheet(meow)

        let app = meow.app
        let link = app.textFields["ssAdd.linkField"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let userinfo = Data("aes-128-gcm:pw".utf8).base64EncodedString()
        link.typeText("ss://\(userinfo)@qr.example.com:443#Scanned")

        let apply = app.buttons["ssAdd.applyLinkButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()

        let server = app.textFields["ssAdd.serverField"]
        XCTAssertEqual(server.value as? String, "qr.example.com")
        XCTAssertEqual(app.textFields["ssAdd.portField"].value as? String, "443")
        XCTAssertEqual(app.textFields["ssAdd.nameField"].value as? String, "Scanned")
    }
}
