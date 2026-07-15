import CryptoKit
import NetworkExtension
import XCTest

// MWCnBypass.m / MWTunnelSettings.m are compiled into this test bundle
// directly (see project.yml MeowIntegrationTests sources), so these tests
// exercise the exact production implementation the extension runs — no
// Swift mirror to drift.

/// Offline verification of the CN-bypass artifact reader: the extension must
/// apply CN route exclusions only from a well-formed artifact whose
/// config-sha256 matches the config it is about to run, and must reject
/// anything that could invalidate the whole excludedRoutes payload.
final class CnBypassArtifactTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "cn-bypass-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func writeConfig(_ yaml: String = "mode: rule\nrules:\n  - GEOIP,CN,DIRECT\n") throws -> URL {
        let url = tempDir.appending(path: "config.yaml")
        try Data(yaml.utf8).write(to: url)
        return url
    }

    private func sha256Hex(of url: URL) throws -> String {
        let digest = try SHA256.hash(data: Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Write an artifact for `configURL`. `sha` overrides the correct hash to
    /// simulate staleness.
    private func writeArtifact(
        for configURL: URL,
        direct: Bool = true,
        cidrs: [String],
        sha: String? = nil,
        header: String = "meow-cn-bypass v1",
    ) throws -> URL {
        let hash = try sha ?? sha256Hex(of: configURL)
        var lines = [header, "config-sha256 \(hash)", "cn-direct \(direct ? 1 : 0)"]
        lines.append(contentsOf: cidrs)
        let url = tempDir.appending(path: "cn-bypass.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    // MARK: - Happy path

    func testValidArtifactParsesV4AndV6Routes() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(
            for: config,
            cidrs: ["1.0.1.0/24", "223.5.5.5/32", "2001:250::/32"],
        )

        let routes = MWCnBypass.load(from: artifact, matchingConfigURL: config)
        let unwrapped = try XCTUnwrap(routes, "well-formed engaged artifact must parse")

        XCTAssertEqual(unwrapped.ipv4Routes.count, 2)
        XCTAssertEqual(unwrapped.ipv4Routes[0].destinationAddress, "1.0.1.0")
        XCTAssertEqual(unwrapped.ipv4Routes[0].destinationSubnetMask, "255.255.255.0")
        XCTAssertEqual(unwrapped.ipv4Routes[1].destinationAddress, "223.5.5.5")
        XCTAssertEqual(unwrapped.ipv4Routes[1].destinationSubnetMask, "255.255.255.255")

        XCTAssertEqual(unwrapped.ipv6Routes.count, 1)
        XCTAssertEqual(unwrapped.ipv6Routes[0].destinationAddress, "2001:250::")
        XCTAssertEqual(unwrapped.ipv6Routes[0].destinationNetworkPrefixLength, 32)
    }

    func testWidePrefixesProduceCorrectMasks() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(for: config, cidrs: ["36.0.0.0/6", "58.0.0.0/8"])

        let routes = try XCTUnwrap(MWCnBypass.load(from: artifact, matchingConfigURL: config))
        XCTAssertEqual(routes.ipv4Routes[0].destinationSubnetMask, "252.0.0.0")
        XCTAssertEqual(routes.ipv4Routes[1].destinationSubnetMask, "255.0.0.0")
    }

    // MARK: - Rejections (full-tunnel fallback)

    func testMissingArtifactReturnsNil() throws {
        let config = try writeConfig()
        let absent = tempDir.appending(path: "nope.txt")
        XCTAssertNil(MWCnBypass.load(from: absent, matchingConfigURL: config))
    }

    func testStaleShaReturnsNil() throws {
        // The artifact was probed from different config bytes than the config
        // the tunnel is about to run — e.g. the user edited the profile after
        // the app's last pre-connect probe. Must fall back to full tunnel.
        let config = try writeConfig()
        let staleSha = String(repeating: "ab", count: 32)
        let artifact = try writeArtifact(for: config, cidrs: ["1.0.1.0/24"], sha: staleSha)
        XCTAssertNil(MWCnBypass.load(from: artifact, matchingConfigURL: config))
    }

    func testDisengagedArtifactReturnsNil() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(for: config, direct: false, cidrs: [])
        XCTAssertNil(MWCnBypass.load(from: artifact, matchingConfigURL: config))
    }

    func testUnknownHeaderVersionReturnsNil() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(
            for: config,
            cidrs: ["1.0.1.0/24"],
            header: "meow-cn-bypass v2",
        )
        XCTAssertNil(MWCnBypass.load(from: artifact, matchingConfigURL: config))
    }

    func testInvalidCidrLineRejectsWholeArtifact() throws {
        // iOS discards the ENTIRE excludedRoutes payload when one destination
        // is invalid, so the reader must reject the whole artifact rather
        // than pass through a partially-validated route set.
        let config = try writeConfig()
        let artifact = try writeArtifact(for: config, cidrs: ["1.0.1.0/24", "999.1.1.1/24"])
        XCTAssertNil(MWCnBypass.load(from: artifact, matchingConfigURL: config))
    }

    func testLoopbackAndDefaultRoutesRejected() throws {
        let config = try writeConfig()
        for poison in ["127.0.0.0/8", "0.0.0.0/0", "1.2.3.4/0", "::1/128", "1.0.1.0/33"] {
            let artifact = try writeArtifact(for: config, cidrs: ["1.0.1.0/24", poison])
            XCTAssertNil(
                MWCnBypass.load(from: artifact, matchingConfigURL: config),
                "\(poison) must reject the artifact",
            )
        }
    }

    func testEngagedArtifactWithoutRoutesReturnsNil() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(for: config, cidrs: [])
        XCTAssertNil(MWCnBypass.load(from: artifact, matchingConfigURL: config))
    }

    // MARK: - Route-set integration (production MWTunnelSettings)

    func testTunnelSettingsAppendCnRoutesAfterLanExclusions() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(
            for: config,
            cidrs: ["1.0.1.0/24", "36.0.0.0/6", "2001:250::/32"],
        )
        let cnBypass = try XCTUnwrap(MWCnBypass.load(from: artifact, matchingConfigURL: config))

        let settings = MWTunnelSettings.make(
            withServerAddress: "192.0.2.1",
            ipv6Enabled: true,
            cnBypass: cnBypass,
        )

        let v4Excluded = settings.ipv4Settings?.excludedRoutes ?? []
        let lanCount = MWTunnelSettings.make(withServerAddress: "192.0.2.1", ipv6Enabled: false)
            .ipv4Settings?.excludedRoutes?.count ?? 0
        XCTAssertEqual(v4Excluded.count, lanCount + 2, "CN v4 routes must append to LAN exclusions")
        XCTAssertEqual(v4Excluded.suffix(2).map(\.destinationAddress), ["1.0.1.0", "36.0.0.0"])

        let v6Excluded = settings.ipv6Settings?.excludedRoutes ?? []
        XCTAssertEqual(
            v6Excluded.last?.destinationAddress,
            "2001:250::",
            "CN v6 route must append to the v6 LAN exclusions",
        )

        let included = settings.ipv4Settings?.includedRoutes ?? []
        XCTAssertEqual(included.first?.destinationAddress, "0.0.0.0", "default route must remain")
    }

    func testTunnelSettingsWithoutBypassMatchLegacyBehavior() {
        let legacy = MWTunnelSettings.make(withServerAddress: "192.0.2.1", ipv6Enabled: false)
        let explicitNil = MWTunnelSettings.make(
            withServerAddress: "192.0.2.1",
            ipv6Enabled: false,
            cnBypass: nil,
        )
        XCTAssertEqual(
            legacy.ipv4Settings?.excludedRoutes?.map(\.destinationAddress),
            explicitNil.ipv4Settings?.excludedRoutes?.map(\.destinationAddress),
        )
        XCTAssertNil(explicitNil.ipv6Settings, "ipv6Settings must stay nil when IPv6 is disabled")
    }

    func testIPv6RoutesIgnoredWhenIPv6Disabled() throws {
        let config = try writeConfig()
        let artifact = try writeArtifact(for: config, cidrs: ["1.0.1.0/24", "2001:250::/32"])
        let cnBypass = try XCTUnwrap(MWCnBypass.load(from: artifact, matchingConfigURL: config))

        let settings = MWTunnelSettings.make(
            withServerAddress: "192.0.2.1",
            ipv6Enabled: false,
            cnBypass: cnBypass,
        )
        XCTAssertNil(settings.ipv6Settings, "no v6 stack → nothing to exclude from")
        XCTAssertEqual(
            settings.ipv4Settings?.excludedRoutes?.last?.destinationAddress,
            "1.0.1.0",
            "v4 CN exclusions still apply with IPv6 off",
        )
    }
}
