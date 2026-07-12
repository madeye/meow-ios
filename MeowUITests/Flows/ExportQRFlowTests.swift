import XCTest

/// Flow: add a Shadowsocks server, then export it back out as a QR code from
/// the subscriptions list. Asserts the sheet renders a QR image whose payload
/// is the server's `ss://` share link.
final class ExportQRFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testExportShadowsocksServerAsQRCode() {
        let meow = MeowApp()
        meow.launch()
        let app = meow.app

        // Add a server manually so the generated local profile exists.
        meow.subscriptionsTab.tap()
        let addMenu = app.buttons["subscriptions.toolbar.add"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.tap()
        let item = app.buttons["subscriptions.toolbar.addShadowsocks"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()

        let server = app.textFields["ssAdd.serverField"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        server.typeText("qr-export.example.com")
        let port = app.textFields["ssAdd.portField"]
        port.tap()
        port.typeText("8388")
        let password = app.secureTextFields["ssAdd.passwordField"]
        password.tap()
        password.typeText("hunter22")
        app.buttons["ssAdd.addButton"].tap()
        XCTAssertTrue(app.staticTexts["My Servers"].waitForExistence(timeout: 10))

        // The generated profile row offers QR export.
        let export = app.buttons["subscriptions.row.exportQR"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()

        // Sheet shows a QR image plus the ss:// share link it encodes.
        XCTAssertTrue(app.images["qrExport.qrImage"].waitForExistence(timeout: 5))
        let payload = app.staticTexts["qrExport.payloadText"]
        XCTAssertTrue(payload.exists)
        XCTAssertTrue((payload.label).hasPrefix("ss://"))

        app.buttons["qrExport.closeButton"].tap()
        XCTAssertFalse(app.images["qrExport.qrImage"].waitForExistence(timeout: 2))
    }
}
