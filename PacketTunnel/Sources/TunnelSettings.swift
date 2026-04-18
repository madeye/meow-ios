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
    static var ipv4LanExcludedRoutes: [NEIPv4Route] {
        [
            route(address: "10.0.0.0", mask: "255.0.0.0"), // RFC 1918 Class A
            route(address: "172.16.0.0", mask: "255.240.0.0"), // RFC 1918 Class B (172.16-172.31)
            route(address: "192.168.0.0", mask: "255.255.0.0"), // RFC 1918 Class C
            route(address: "169.254.0.0", mask: "255.255.0.0"), // Link-local (DHCP fallback)
            route(address: "127.0.0.0", mask: "255.0.0.0"), // Loopback
            route(address: "224.0.0.0", mask: "240.0.0.0"), // Multicast (mDNS, Bonjour, AirPlay)
            route(address: "255.255.255.255", mask: "255.255.255.255"), // Limited broadcast
        ]
    }

    /// IPv6 equivalents: ULA + link-local + loopback + multicast. Computed
    /// for the same Sendable reason as `ipv4LanExcludedRoutes`.
    static var ipv6LanExcludedRoutes: [NEIPv6Route] {
        [
            route6(address: "fc00::", prefix: 7), // Unique Local Addresses (ULA)
            route6(address: "fe80::", prefix: 10), // Link-local
            route6(address: "::1", prefix: 128), // Loopback
            route6(address: "ff00::", prefix: 8), // Multicast
        ]
    }

    static func make(serverAddress: String) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = ipv4LanExcludedRoutes
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = ipv6LanExcludedRoutes
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: ["172.19.0.2"])
        dns.matchDomains = [""]
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
