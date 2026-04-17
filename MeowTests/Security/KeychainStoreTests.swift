import Testing
import Foundation

/// Keychain tests verify the shared access group works for both the app and
/// the extension. Access group must be
/// `$(AppIdentifierPrefix)io.github.madeye.meow` (see
/// `App/App.entitlements` and `PacketTunnel/PacketTunnel.entitlements`).
@Suite("KeychainStore", .tags(.security))
struct KeychainStoreTests {

    @Test("set → get round-trip for String", .disabled("blocked on KeychainStore implementation"))
    func testStringRoundTrip() throws {
        // KeychainStore.set("s3cret", forKey: "testKey")
        // #expect(KeychainStore.get("testKey") == "s3cret")
        // KeychainStore.delete(forKey: "testKey")
    }

    @Test("set → get round-trip for Data", .disabled("blocked on KeychainStore"))
    func testDataRoundTrip() throws {}

    @Test("delete is idempotent", .disabled("blocked on KeychainStore"))
    func testDeleteIdempotent() throws {
        // two delete calls on a non-existent key do not throw
    }

    @Test("uses kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", .disabled("blocked on KeychainStore"))
    func testAccessibilityClass() throws {
        // verify the SecItem query has the correct kSecAttrAccessible value
        // ship-blocker: MUST NOT use kSecAttrAccessibleAlways
    }

    @Test("access group matches extension entitlement", .disabled("blocked on KeychainStore"))
    func testAccessGroup() throws {
        // kSecAttrAccessGroup = "$(AppIdentifierPrefix)io.github.madeye.meow"
    }
}

extension Tag {
    @Tag static var security: Self
}
