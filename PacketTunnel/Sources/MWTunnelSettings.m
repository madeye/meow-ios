#import "MWTunnelSettings.h"

@implementation MWTunnelSettings

+ (NEPacketTunnelNetworkSettings *)makeWithServerAddress:(NSString *)serverAddress {
    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:serverAddress];

    // IPv4
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc]
        initWithAddresses:@[@"172.19.0.1"]
              subnetMasks:@[@"255.255.255.252"]];
    ipv4.includedRoutes = @[[NEIPv4Route defaultRoute]];
    ipv4.excludedRoutes = [self ipv4LanExcludedRoutes];
    settings.IPv4Settings = ipv4;

    // IPv6 — intentionally NOT configured. This tunnel is IPv4-only:
    // settings.IPv6Settings is left nil, so the TUN claims no IPv6 address
    // and installs no IPv6 routes.
    //
    // Leak-around note: with no ::/0 route claimed, apps on a v6-capable
    // network could in principle reach the internet natively over IPv6,
    // bypassing the proxy. In practice meow-dns strips AAAA unconditionally
    // (fake-IP runs a v4-only pool), so clients fall back to A / fake-v4 and
    // the proxy connects by hostname. The residual surface is hardcoded v6
    // literals (rare), which simply fail to reach the proxy.
    //
    // IPv4↔IPv6 path transitions are handled by the path monitor's
    // address-family restart in PacketTunnelProvider.

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

@end
