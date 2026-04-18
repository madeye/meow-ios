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
        // The 172.16/12 RFC 1918 block is split four ways so that 172.19/16
        // (the tunnel's own virtual interface + DNS server) stays routed
        // through the tunnel. A single 172.16.0.0/255.240.0.0 entry here would
        // shadow the tunnel DNS and stop traffic.
        let expected: [(String, String)] = [
            ("10.0.0.0", "255.0.0.0"),
            ("172.16.0.0", "255.254.0.0"),
            ("172.18.0.0", "255.255.0.0"),
            ("172.20.0.0", "255.252.0.0"),
            ("172.24.0.0", "255.248.0.0"),
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

    /// Regression guard: if anyone re-introduces a broad 172.16/12 exclusion
    /// (mask 255.240.0.0), this test fails. That exact exclusion is what
    /// swallowed the tunnel DNS server 172.19.0.2 in the original LAN-exclusion
    /// shipment and killed all traffic.
    func testMakeDoesNotExcludeTunnelSubnet() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")
        let routes = settings.ipv4Settings?.excludedRoutes ?? []
        for route in routes {
            XCTAssertFalse(
                route.destinationAddress == "172.16.0.0" && route.destinationSubnetMask == "255.240.0.0",
                "172.16/12 exclusion shadows the tunnel's own 172.19/16 interface and must not be re-introduced",
            )
        }
    }

    func testMakeLeavesDNSMatchDomainsUnset() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")
        XCTAssertNil(
            settings.dnsSettings?.matchDomains,
            "matchDomains must stay nil (default 'match all'); empty-string entries have been observed to drop queries",
        )
    }

    func testMakeAppliesIPv6LANExcludedRoutesInDeclaredOrder() {
        // fc00::/7 (ULA) is intentionally absent for this iteration. The
        // tunnel's own fdfe:dcba:9876::/126 sits inside that block, so the
        // same shadowing risk as 172.16/12 applies. A split ULA exclusion
        // will land in a follow-up once the v4 narrow fix is confirmed green.
        let expected: [(String, Int)] = [
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
