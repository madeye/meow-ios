import NetworkExtension
import XCTest

// `TunnelSettings.swift` is compiled into this test bundle directly (see
// project.yml MeowIntegrationTests sources). App extensions are bundled
// binaries, not linkable libraries, so @testable import PacketTunnel fails
// at link time; shared-source target membership is the standard Xcode
// pattern for exercising extension-internal code from a unit test.

/// Offline, deterministic verification that `TunnelSettings.make(...)` emits
/// the LAN-exclusion routes we promise users. If any route in the expected
/// set is dropped, or a stray route sneaks in, this test fails — no device
/// or packet capture required. Pair with a manual VPN-on/LAN-access smoke
/// on device before ship.
final class TunnelSettingsLANExclusionTests: XCTestCase {
    func testMakeAppliesIPv4LANExcludedRoutesInDeclaredOrder() {
        let expected: [(String, String)] = [
            ("10.0.0.0", "255.0.0.0"),
            ("172.16.0.0", "255.240.0.0"),
            ("192.168.0.0", "255.255.0.0"),
            ("169.254.0.0", "255.255.0.0"),
            ("127.0.0.0", "255.0.0.0"),
            ("224.0.0.0", "240.0.0.0"),
            ("255.255.255.255", "255.255.255.255"),
        ]

        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")
        let routes = settings.ipv4Settings?.excludedRoutes ?? []

        XCTAssertEqual(routes.count, expected.count, "excludedRoutes count mismatch")
        for (index, (address, mask)) in expected.enumerated() {
            let route = routes[index]
            XCTAssertEqual(route.destinationAddress, address, "index \(index) destinationAddress")
            XCTAssertEqual(route.destinationSubnetMask, mask, "index \(index) destinationSubnetMask")
        }
    }

    func testMakeAppliesIPv6LANExcludedRoutesInDeclaredOrder() {
        let expected: [(String, Int)] = [
            ("fc00::", 7),
            ("fe80::", 10),
            ("::1", 128),
            ("ff00::", 8),
        ]

        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")
        let routes = settings.ipv6Settings?.excludedRoutes ?? []

        XCTAssertEqual(routes.count, expected.count, "excludedRoutes count mismatch")
        for (index, (address, prefix)) in expected.enumerated() {
            let route = routes[index]
            XCTAssertEqual(route.destinationAddress, address, "index \(index) destinationAddress")
            XCTAssertEqual(route.destinationNetworkPrefixLength.intValue, prefix, "index \(index) prefix length")
        }
    }

    func testMakeStillRoutesAllTrafficByDefault() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")

        let ipv4Included = settings.ipv4Settings?.includedRoutes ?? []
        XCTAssertEqual(ipv4Included.count, 1, "catch-all default route should remain")
        XCTAssertEqual(ipv4Included.first?.destinationAddress, "0.0.0.0")

        let ipv6Included = settings.ipv6Settings?.includedRoutes ?? []
        XCTAssertEqual(ipv6Included.count, 1)
        XCTAssertEqual(ipv6Included.first?.destinationAddress, "::")
    }
}
