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

    /// Regression guard: iOS's `NEIPv4Route`/`NEIPv6Route` validator rejects
    /// any loopback destination and discards the ENTIRE excludedRoutes payload
    /// when it finds one. A single 127/8 or ::1 entry in #53/#54 killed every
    /// other exclusion silently — ingress log showed zero packets. If anyone
    /// re-introduces a loopback exclusion, this test fails before it ships.
    func testMakeExcludesNoLoopbackDestinations() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")

        let ipv4Routes = settings.ipv4Settings?.excludedRoutes ?? []
        for route in ipv4Routes {
            XCTAssertFalse(
                route.destinationAddress.hasPrefix("127."),
                "IPv4 excludedRoute \(route.destinationAddress) is loopback — iOS rejects the whole payload",
            )
        }

        let ipv6Routes = settings.ipv6Settings?.excludedRoutes ?? []
        for route in ipv6Routes {
            // Anchor the match so we reject "::1" exactly but not something
            // coincidentally like "::1abc" (which is not a real route but
            // keeps the guard robust against future additions).
            let addr = route.destinationAddress
            XCTAssertFalse(
                addr == "::1" || addr == "0:0:0:0:0:0:0:1",
                "IPv6 excludedRoute \(addr) is loopback — iOS rejects the whole payload",
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

    /// IPv6 disabled (the default): ipv6Settings must be left nil so the TUN
    /// claims no IPv6 address and installs no IPv6 routes — the tunnel is
    /// IPv4-only and the FFI drops AAAA.
    func testMakeConfiguresNoIPv6WhenDisabled() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")
        XCTAssertNil(settings.ipv6Settings, "ipv6Settings must stay nil when IPv6 is disabled")
    }

    /// IPv6 enabled: the TUN must claim a ULA address and a ::/0 default route
    /// (so real-IPv6 destinations are proxied instead of leaking natively),
    /// with link-local / ULA / multicast excluded — mirroring the IPv4 policy.
    func testMakeConfiguresIPv6WhenEnabled() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1", ipv6Enabled: true)
        let ipv6 = settings.ipv6Settings
        XCTAssertNotNil(ipv6, "ipv6Settings must be configured when IPv6 is enabled")
        XCTAssertEqual(ipv6?.addresses, ["fd6d:6577::1"], "expected the ULA tunnel address")

        let included = ipv6?.includedRoutes ?? []
        XCTAssertEqual(included.count, 1, "catch-all v6 default route should be present")
        XCTAssertEqual(included.first?.destinationAddress, "::")

        let expectedExclusions: [(String, NSNumber)] = [
            ("fe80::", 10),
            ("fc00::", 7),
            ("ff00::", 8),
        ]
        let excluded = ipv6?.excludedRoutes ?? []
        XCTAssertEqual(excluded.count, expectedExclusions.count, "v6 excludedRoutes count mismatch")
        for (index, (address, prefix)) in expectedExclusions.enumerated() {
            XCTAssertEqual(excluded[index].destinationAddress, address, "index \(index) v6 destinationAddress")
            XCTAssertEqual(
                excluded[index].destinationNetworkPrefixLength,
                prefix,
                "index \(index) v6 prefix length",
            )
        }
    }

    func testMakeStillRoutesAllTrafficByDefault() {
        let settings = TunnelSettings.make(serverAddress: "192.0.2.1")

        let ipv4Included = settings.ipv4Settings?.includedRoutes ?? []
        XCTAssertEqual(ipv4Included.count, 1, "catch-all default route should remain")
        XCTAssertEqual(ipv4Included.first?.destinationAddress, "0.0.0.0")
    }
}
