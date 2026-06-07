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

    // IPv6 — claimed unconditionally, even on IPv4-only networks. This is
    // a deliberate sinkhole, not an oversight:
    //
    //   * Claiming ::/0 prevents IPv6 leak-around: on a v6-capable network,
    //     apps would otherwise reach the internet natively over v6,
    //     bypassing the proxy entirely.
    //   * It costs nothing on a v4-only network because almost no v6
    //     traffic enters the TUN: the engine's resolver runs fake-IP with a
    //     v4-only pool, and meow-dns answers AAAA with NOERROR-empty in
    //     that configuration, so clients fall back to A / fake-v4 and the
    //     proxy connects by hostname. Only hardcoded v6 literals (rare)
    //     ever route in, and those fail fast at the engine's dial.
    //   * Do NOT make this conditional on path capability: re-applying
    //     network settings mid-tunnel reasserts the whole payload (fragile —
    //     see the loopback-route lesson in ipv4LanExcludedRoutes) and
    //     IPv4↔IPv6 transitions are already handled by the path monitor's
    //     address-family restart in PacketTunnelProvider.
    NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc]
        initWithAddresses:@[@"fdfe:dcba:9876::1"]
     networkPrefixLengths:@[@126]];
    ipv6.includedRoutes = @[[NEIPv6Route defaultRoute]];
    ipv6.excludedRoutes = [self ipv6LanExcludedRoutes];
    settings.IPv6Settings = ipv6;

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
    // ::1/128 intentionally omitted — iOS rejects loopback destinations
    return @[
        [[NEIPv6Route alloc] initWithDestinationAddress:@"fe80::" networkPrefixLength:@10],
        [[NEIPv6Route alloc] initWithDestinationAddress:@"ff00::" networkPrefixLength:@8],
    ];
}

@end
