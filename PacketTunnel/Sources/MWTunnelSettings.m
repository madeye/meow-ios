#import "MWTunnelSettings.h"

@implementation MWTunnelSettings

+ (NEPacketTunnelNetworkSettings *)makeWithServerAddress:(NSString *)serverAddress
                                             ipv6Enabled:(BOOL)ipv6Enabled {
    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:serverAddress];

    // IPv4
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc]
        initWithAddresses:@[@"172.19.0.1"]
              subnetMasks:@[@"255.255.255.252"]];
    ipv4.includedRoutes = @[[NEIPv4Route defaultRoute]];
    ipv4.excludedRoutes = [self ipv4LanExcludedRoutes];
    settings.IPv4Settings = ipv4;

    // IPv6 — configured only when the user enables IPv6 in app settings. When
    // off (the default), settings.IPv6Settings is left nil so the TUN claims no
    // IPv6 address and installs no v6 routes, and the FFI answers AAAA queries
    // NOERROR-empty (meow_tun_set_ipv6_enabled(0)) so clients fall back to the
    // IPv4 path. This keeps the tunnel IPv4-only by default.
    //
    // When on, we claim a private (ULA) v6 address and a ::/0 default route so
    // real-IPv6 destinations (meow-dns now returns AAAA) enter the netstack and
    // are proxied, instead of leaking natively over a v6-capable network. The
    // FFI is told to forward AAAA via meow_tun_set_ipv6_enabled(1) in
    // MWTunnelEngine — the two must stay in sync (both read the same pref).
    //
    // Leak-around note: hardcoded v6 literals (no DNS) are now proxied too via
    // the default route; only the explicitly excluded LAN/link-local ranges
    // bypass the tunnel, mirroring the IPv4 LAN-exclusion policy.
    //
    // IPv4↔IPv6 path transitions are handled by the path monitor's
    // address-family restart in PacketTunnelProvider.
    if (ipv6Enabled) {
        NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc]
            initWithAddresses:@[@"fd6d:6577::1"]
            networkPrefixLengths:@[@64]];
        ipv6.includedRoutes = @[[NEIPv6Route defaultRoute]];
        ipv6.excludedRoutes = [self ipv6LanExcludedRoutes];
        settings.IPv6Settings = ipv6;
    }

    // DNS
    NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:@[@"172.19.0.2"]];
    settings.DNSSettings = dns;

    // Conservative MSS clamp for PMTU black-holes on the upstream side.
    // The app's TCP stack derives MSS from this MTU (1400 - 40 = 1360),
    // so all payloads entering the TUN are ≤1360 bytes. When meow
    // re-emits them on a real upstream socket, the kernel's outbound
    // segment fits inside even pathological path MTUs (1428 on some
    // cellular carriers, 1380 on iCloud Private Relay-style paths, etc.)
    // without needing PMTUD — which routinely black-holes on CN routes
    // where ICMP Fragmentation Needed is filtered.
    //
    // 1400 matches the conservative default used by Surge / Quantumult X
    // / Loon. The ~6% throughput overhead on Wi-Fi paths that didn't
    // need the clamp is the price for not relying on PMTUD.
    //
    // Follow-up: dynamic clamping via NWPathMonitor + getifaddrs/
    // SIOCGIFMTU on the primary interface — see investigation doc.
    settings.MTU = @1400;
    return settings;
}

+ (NSArray<NEIPv4Route *> *)ipv4LanExcludedRoutes {
    return @[
        [[NEIPv4Route alloc] initWithDestinationAddress:@"10.0.0.0"      subnetMask:@"255.0.0.0"],
        // 172.16/12 split to skip 172.19/16 (tunnel interface + DNS)
        [[NEIPv4Route alloc] initWithDestinationAddress:@"172.16.0.0"    subnetMask:@"255.254.0.0"],
        [[NEIPv4Route alloc] initWithDestinationAddress:@"172.18.0.0"    subnetMask:@"255.255.0.0"],
        [[NEIPv4Route alloc] initWithDestinationAddress:@"172.20.0.0"    subnetMask:@"255.252.0.0"],
        [[NEIPv4Route alloc] initWithDestinationAddress:@"172.24.0.0"    subnetMask:@"255.248.0.0"],
        [[NEIPv4Route alloc] initWithDestinationAddress:@"192.168.0.0"   subnetMask:@"255.255.0.0"],
        [[NEIPv4Route alloc] initWithDestinationAddress:@"169.254.0.0"   subnetMask:@"255.255.0.0"],
        // 127/8 intentionally omitted — iOS rejects loopback and drops the whole excludedRoutes payload
        [[NEIPv4Route alloc] initWithDestinationAddress:@"224.0.0.0"     subnetMask:@"240.0.0.0"],
        [[NEIPv4Route alloc] initWithDestinationAddress:@"255.255.255.255" subnetMask:@"255.255.255.255"],
    ];
}

+ (NSArray<NEIPv6Route *> *)ipv6LanExcludedRoutes {
    // Mirror the IPv4 LAN-exclusion policy for v6: keep link-local, unique
    // local (ULA, incl. the TUN's own fd6d:6577::/64), and multicast off the
    // ::/0 default route so local/link traffic bypasses the tunnel.
    return @[
        [[NEIPv6Route alloc] initWithDestinationAddress:@"fe80::" networkPrefixLength:@10], // link-local
        [[NEIPv6Route alloc] initWithDestinationAddress:@"fc00::" networkPrefixLength:@7],  // unique local (ULA)
        [[NEIPv6Route alloc] initWithDestinationAddress:@"ff00::" networkPrefixLength:@8],  // multicast
    ];
}

@end
