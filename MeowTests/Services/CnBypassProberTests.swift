@testable import meow_ios
import XCTest

/// End-to-end exercise of the app-side CN-bypass probe through the real FFI
/// (`meow_config_cn_bypass_probe`). Uses a config WITHOUT GeoIP rules so the
/// probe never needs Country.mmdb — keeping the test hermetic on fresh
/// simulators. The engaged path (GEOIP,CN,DIRECT → CIDR dump) is covered by
/// the Rust unit tests in cn_bypass.rs against the MaxMind fixture MMDB, and
/// artifact consumption by CnBypassArtifactTests in MeowIntegrationTests.
final class CnBypassProberTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "cn-probe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testProbeWritesDisengagedArtifactForConfigWithoutGeoipCn() throws {
        let configURL = tempDir.appending(path: "config.yaml")
        try Data("mode: rule\nrules:\n  - MATCH,DIRECT\n".utf8).write(to: configURL)
        let artifactURL = tempDir.appending(path: "cn-bypass.txt")

        let engaged = CnBypassProber.probe(configURL: configURL, artifactURL: artifactURL)

        XCTAssertFalse(engaged, "MATCH,DIRECT without GEOIP,CN must not engage the bypass")
        let artifact = try String(contentsOf: artifactURL, encoding: .utf8)
        XCTAssertTrue(artifact.hasPrefix("meow-cn-bypass v1\n"), "artifact header missing")
        XCTAssertTrue(artifact.contains("\ncn-direct 0\n"), "artifact must record the negative verdict")
    }

    func testProbeFailsCleanlyOnMissingConfig() {
        let configURL = tempDir.appending(path: "missing.yaml")
        let artifactURL = tempDir.appending(path: "cn-bypass.txt")

        let engaged = CnBypassProber.probe(configURL: configURL, artifactURL: artifactURL)

        XCTAssertFalse(engaged)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifactURL.path),
            "a failed probe must not write an artifact",
        )
    }
}
