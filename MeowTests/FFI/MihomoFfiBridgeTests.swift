import Testing
import Foundation

/// Thin smoke tests for the Rust `mihomo-ios-ffi` static library exposed via
/// the bridging header. These ride the C ABI directly — any drift in symbol
/// names or parameter types breaks these tests before any view-layer test
/// even runs.
///
/// Lives in the app-side test bundle (not the extension bundle) because the
/// same header is linked into both; the extension-side bridge coverage lives
/// in `MeowIntegrationTests/EngineIntegration/`.
@Suite("mihomo-ios-ffi Swift bridge", .tags(.ffi))
struct MihomoFfiBridgeTests {

    @Test("meow_tun_init is callable and idempotent", .disabled("blocked on T1.4 xcframework"))
    func testInitIdempotent() {
        // meow_tun_init()
        // meow_tun_init()
        // #expect(true, "two init calls should not crash")
    }

    @Test("meow_tun_set_home_dir accepts UTF-8", .disabled("blocked on T1.4"))
    func testSetHomeDirUtf8() {
        // "非ASCII/路径".withCString { meow_tun_set_home_dir($0) }
    }

    @Test("meow_tun_last_error is empty before any failure", .disabled("blocked on T1.4"))
    func testNoErrorInitially() {
        // #expect(String(cString: meow_tun_last_error()) == "")
    }

    @Test("meowValidateConfig surfaces YAML errors", .disabled("blocked on T1.4"))
    func testValidateConfigMalformed() {
        // invalid YAML → non-zero return + populated last_error
    }
}

extension Tag {
    @Tag static var ffi: Self
}
