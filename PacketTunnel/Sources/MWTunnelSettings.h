#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

/// The TUN's own IPv4 address (NEIPv4Settings) and the in-TUN DNS server
/// address advertised via NEDNSSettings. Shared with the data-path health
/// probe, which forges a resolver query in exactly this shape.
extern NSString *const MWTunnelClientIPv4Address;
extern NSString *const MWTunnelDNSServerIPv4Address;

@interface MWTunnelSettings : NSObject
+ (NEPacketTunnelNetworkSettings *)makeWithServerAddress:(NSString *)serverAddress
                                             ipv6Enabled:(BOOL)ipv6Enabled;
@end
