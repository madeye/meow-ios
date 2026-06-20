import Foundation
import NetworkExtension

enum TunnelSettings {
    /// RFC 1918 private + link-local + loopback + multicast + broadcast.
    /// Excluded from the tunnel so LAN (router, printer, NAS, AirPlay/Bonjour,
    /// mDNS) stays reachable while the VPN is up. `gatewayAddress = nil` tells
    /// iOS to route these direct via the interface default.
    ///
    /// Exposed as a computed property because `NEIPv4Route` is a non-Sendable
    /// ObjC class and Swift 6 strict concurrency rejects a `static let` of it.
    /// The 172.16/12 block is split four ways so 172.19/16 — the tunnel's own
    /// virtual interface (172.19.0.1/30) and DNS server (172.19.0.2) — stays
    /// routed through the tunnel. Excluding 172.19.x made iOS hand the tunnel
    /// DNS query to the physical interface, where it had nowhere to go.
    static var ipv4LanExcludedRoutes: [NEIPv4Route] {
        [
            route(address: "10.0.0.0", mask: "255.0.0.0"), // RFC 1918 Class A
            // 172.16/12 split to skip 172.19/16 (tunnel interface + DNS):
            route(address: "172.16.0.0", mask: "255.254.0.0"), // 172.16-172.17 (/15)
            route(address: "172.18.0.0", mask: "255.255.0.0"), // 172.18 (/16)
            route(address: "172.20.0.0", mask: "255.252.0.0"), // 172.20-172.23 (/14)
            route(address: "172.24.0.0", mask: "255.248.0.0"), // 172.24-172.31 (/13)
            route(address: "192.168.0.0", mask: "255.255.0.0"), // RFC 1918 Class C
            route(address: "169.254.0.0", mask: "255.255.0.0"), // Link-local (DHCP fallback)
            // Loopback (127/8) intentionally omitted: iOS's NEIPv4Route validator rejects
            // any loopback destination and throws out the ENTIRE excludedRoutes payload, so
            // including it silently broke all other exclusions. The kernel handles 127/8
            // host-locally without needing a TUN exclusion anyway.
            route(address: "224.0.0.0", mask: "240.0.0.0"), // Multicast (mDNS, Bonjour, AirPlay)
            route(address: "255.255.255.255", mask: "255.255.255.255"), // Limited broadcast
        ]
    }

    /// IPv6 LAN exclusions, mirrored from MWTunnelSettings.ipv6LanExcludedRoutes:
    /// keep link-local, unique-local (ULA, incl. the TUN's own fd6d:6577::/64),
    /// and multicast off the ::/0 default route, mirroring the IPv4 policy.
    static var ipv6LanExcludedRoutes: [NEIPv6Route] {
        [
            route6(address: "fe80::", prefix: 10), // link-local
            route6(address: "fc00::", prefix: 7), // unique local (ULA)
            route6(address: "ff00::", prefix: 8), // multicast
        ]
    }

    static func make(serverAddress: String, ipv6Enabled: Bool = false) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = ipv4LanExcludedRoutes
        settings.ipv4Settings = ipv4

        // IPv6 is configured only when enabled in app settings (mirrors
        // MWTunnelSettings.makeWithServerAddress:ipv6Enabled:). When off, the
        // TUN claims no IPv6 address/routes and the FFI drops AAAA so the tunnel
        // is IPv4-only. When on, claim a ULA address + ::/0 default route so
        // real-IPv6 destinations enter the tunnel instead of leaking natively.
        if ipv6Enabled {
            let ipv6 = NEIPv6Settings(addresses: ["fd6d:6577::1"], networkPrefixLengths: [64])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            ipv6.excludedRoutes = ipv6LanExcludedRoutes
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: ["172.19.0.2"])
        // Leaving matchDomains at its default (nil) — see NEDNSSettings.h,
        // which describes the default as "match all domains". Passing [""]
        // was a no-op at best and risked being interpreted as an empty-suffix
        // match that some iOS revisions drop on the floor.
        settings.dnsSettings = dns

        settings.mtu = 1500
        return settings
    }

    private static func route(address: String, mask: String) -> NEIPv4Route {
        NEIPv4Route(destinationAddress: address, subnetMask: mask)
    }

    private static func route6(address: String, prefix: Int) -> NEIPv6Route {
        NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
    }
}
