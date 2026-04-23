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

    // IPv6
    NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc]
        initWithAddresses:@[@"fdfe:dcba:9876::1"]
     networkPrefixLengths:@[@126]];
    ipv6.includedRoutes = @[[NEIPv6Route defaultRoute]];
    ipv6.excludedRoutes = [self ipv6LanExcludedRoutes];
    settings.IPv6Settings = ipv6;

    // DNS
    NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:@[@"172.19.0.2"]];
    settings.DNSSettings = dns;

    settings.MTU = @1500;
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
