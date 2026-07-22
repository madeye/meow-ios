import XCTest

/// Flow: export a Shadowsocks server as a QR code from the subscriptions
/// list. The generated local profile is seeded via `-SeedShadowsocksProfile`
/// rather than driving the add flow — its password SecureField triggers an
/// iOS "Save Password?" dialog that covers the list (same reason the rename
/// flow seeds via `-SeedProfile`).
final class ExportQRFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testExportShadowsocksServerAsQRCode() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests", "-ResetState", "-SeedShadowsocksProfile", "My Servers"]
        app.launch()

        app.tabBars.buttons["Configs"].tap()
        XCTAssertTrue(app.staticTexts["My Servers"].waitForExistence(timeout: 5))

        // The generated profile row offers QR export.
        let export = app.buttons["subscriptions.row.exportQR"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()

        // Sheet shows a QR image plus the ss:// share link it encodes.
        XCTAssertTrue(app.images["qrExport.qrImage"].waitForExistence(timeout: 5))
        let payload = app.staticTexts["qrExport.payloadText"]
        XCTAssertTrue(payload.exists)
        XCTAssertTrue(payload.label.hasPrefix("ss://"))

        app.buttons["qrExport.closeButton"].tap()
        XCTAssertFalse(app.images["qrExport.qrImage"].waitForExistence(timeout: 2))
    }
}
