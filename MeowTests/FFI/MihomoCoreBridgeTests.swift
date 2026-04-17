import Testing
import Foundation

/// Thin smoke tests for the unified Rust `mihomo-ios-ffi` static library
/// exposed via the `MihomoCore.xcframework` C ABI. These ride the C ABI
/// directly — any drift in symbol names or parameter types breaks these
/// tests before any view-layer test runs.
///
/// The same header is linked into both the app target and the PacketTunnel
/// extension; this suite lives in the app-side test bundle. Extension-side
/// lifecycle coverage (engine start/stop, tun2socks) lives in
/// `MeowIntegrationTests/EngineIntegration/` once the xcframework builds.
@Suite("mihomo-core Swift bridge", .tags(.ffi))
struct MihomoCoreBridgeTests {

    @Test("meow_core_init is callable and idempotent", .disabled("blocked on T2.4 xcframework"))
    func testInitIdempotent() {
        // meow_core_init()
        // meow_core_init()
        // #expect(true, "two init calls should not crash")
    }

    @Test("meow_core_set_home_dir accepts UTF-8", .disabled("blocked on T2.4"))
    func testSetHomeDirUtf8() {
        // "非ASCII/路径".withCString { meow_core_set_home_dir($0) }
    }

    @Test("meow_core_last_error is empty before any failure", .disabled("blocked on T2.4"))
    func testNoErrorInitially() {
        // #expect(String(cString: meow_core_last_error()) == "")
    }

    @Test("meow_engine_is_running is 0 before start", .disabled("blocked on T2.4"))
    func testIsRunningFalseByDefault() {
        // #expect(meow_engine_is_running() == 0)
    }

    @Test("meow_engine_validate_config surfaces YAML errors", .disabled("blocked on T2.4"))
    func testValidateConfigMalformed() {
        // invalid YAML → non-zero return + populated last_error
    }

    @Test("meow_engine_convert_subscription roundtrips Clash YAML", .disabled("blocked on T2.4"))
    func testConvertSubscriptionPassthrough() {
        // Clash YAML body → same YAML out
    }
}

extension Tag {
    @Tag static var ffi: Self
}
