import XCTest

/// Launch helpers for UI tests. Wraps `XCUIApplication` with the standard
/// set of launch arguments so every test suite starts from a known state.
struct MeowApp {
    let app: XCUIApplication

    init(resetState: Bool = true, stubbedRESTBase: String? = nil) {
        app = XCUIApplication()
        app.launchArguments.append("-UITests")
        if resetState { app.launchArguments.append("-ResetState") }
        if let base = stubbedRESTBase {
            app.launchArguments.append(contentsOf: ["-StubURL", base])
        }
    }

    func launch() {
        app.launch()
    }

    /// Tab navigation
    var homeTab: XCUIElement {
        app.tabBars.buttons["Home"]
    }

    var subscriptionsTab: XCUIElement {
        app.tabBars.buttons["Subscriptions"]
    }

    var trafficTab: XCUIElement {
        app.tabBars.buttons["Traffic"]
    }

    var logsTab: XCUIElement {
        app.tabBars.buttons["Logs"]
    }

    var settingsTab: XCUIElement {
        app.tabBars.buttons["Settings"]
    }

    /// Page objects — thin wrappers; fill in as views land.
    var home: HomeScreen {
        HomeScreen(app: app)
    }

    var subscriptions: SubscriptionsScreen {
        SubscriptionsScreen(app: app)
    }
}

struct HomeScreen {
    let app: XCUIApplication
    var vpnToggle: XCUIElement {
        app.buttons["vpn.toggle"]
    }

    var statusLabel: XCUIElement {
        app.staticTexts["vpn.status"]
    }

    var uploadRate: XCUIElement {
        app.staticTexts["traffic.uploadRate"]
    }

    var downloadRate: XCUIElement {
        app.staticTexts["traffic.downloadRate"]
    }

    var routeModePicker: XCUIElement {
        app.buttons["routeMode.picker"]
    }
}

struct SubscriptionsScreen {
    let app: XCUIApplication
    var addButton: XCUIElement {
        app.navigationBars.buttons["subscriptions.add"]
    }

    var nameField: XCUIElement {
        app.textFields["subscription.name"]
    }

    var urlField: XCUIElement {
        app.textFields["subscription.url"]
    }

    var submitButton: XCUIElement {
        app.buttons["subscription.submit"]
    }

    func row(named name: String) -> XCUIElement {
        app.cells["subscription.row.\(name)"]
    }
}
