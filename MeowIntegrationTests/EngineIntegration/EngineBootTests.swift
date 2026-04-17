import XCTest

/// Verifies the Rust + Go engines can be booted, coexist, and are reachable
/// via the REST controller at 127.0.0.1:9090 from within the extension
/// process. These tests link against the real xcframeworks and MUST run
/// inside the extension-hosted test bundle.
final class EngineBootTests: XCTestCase {

    func testGoEngineStartsAndRESTReachable() async throws {
        throw XCTSkip("blocked on T3.3 + hosted-test-bundle setup")
        // seed config.yaml in App Group container, call meowEngineStart
        // HTTP GET http://127.0.0.1:9090/version within 2s → 200
    }

    func testRustTun2socksAndGoEngineCoexist() async throws {
        throw XCTSkip("blocked on T3.5")
    }

    func testDohBootstrapResolvesTestDomain() async throws {
        throw XCTSkip("blocked on T1.4 DoH path")
    }

    func testGeoipAssetsCopiedOnFirstLaunch() async throws {
        throw XCTSkip("blocked on T3.2")
    }

    func testExtensionMemoryUnder40MBAt60sIdle() async throws {
        throw XCTSkip("blocked on T3.7 + measurable harness")
        // proc_task_info, assert resident_size < 40 MB after 60s post-connect
    }
}
