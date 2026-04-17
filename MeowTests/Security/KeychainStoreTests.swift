import Foundation
import Testing

/// Keychain tests verify the shared access group works for both the app and
/// the extension. Access group must be
/// `$(AppIdentifierPrefix)io.github.madeye.meow` (see
/// `App/App.entitlements` and `PacketTunnel/PacketTunnel.entitlements`).
@Suite("KeychainStore", .tags(.security))
struct KeychainStoreTests {
    @Test(.disabled("blocked on KeychainStore implementation"))
    func `set → get round-trip for String`() {
        // KeychainStore.set("s3cret", forKey: "testKey")
        // #expect(KeychainStore.get("testKey") == "s3cret")
        // KeychainStore.delete(forKey: "testKey")
    }

    @Test(.disabled("blocked on KeychainStore"))
    func `set → get round-trip for Data`() {}

    @Test(.disabled("blocked on KeychainStore"))
    func `delete is idempotent`() {
        // two delete calls on a non-existent key do not throw
    }

    @Test(.disabled("blocked on KeychainStore"))
    func `uses kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`() {
        // verify the SecItem query has the correct kSecAttrAccessible value
        // ship-blocker: MUST NOT use kSecAttrAccessibleAlways
    }

    @Test(.disabled("blocked on KeychainStore"))
    func `access group matches extension entitlement`() {
        // kSecAttrAccessGroup = "$(AppIdentifierPrefix)io.github.madeye.meow"
    }
}

extension Tag {
    @Tag static var security: Self
}
