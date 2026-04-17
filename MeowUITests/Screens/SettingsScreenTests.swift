import XCTest

final class SettingsScreenTests: XCTestCase {
    func testTogglesPersistAcrossRelaunch() throws {
        throw XCTSkip("blocked on T5.8")
        // toggle Allow LAN, relaunch, verify still on
    }

    func testDoHUrlValidation() throws {
        throw XCTSkip("blocked on T5.8")
        // enter "not-a-url", blur → validation error; enter "https://dns.google/dns-query" → accepted
    }

    func testVersionStringMatchesBundle() throws {
        throw XCTSkip("blocked on T5.8")
    }

    func testMemoryUsageDisplayFormat() throws {
        throw XCTSkip("blocked on T5.8 + /memory poll")
        // should display "<number> MB / <number> MB"
    }
}
