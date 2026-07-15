#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "MWCnBypass.h"

NS_ASSUME_NONNULL_BEGIN

@interface MWTunnelSettings : NSObject
+ (NEPacketTunnelNetworkSettings *)makeWithServerAddress:(NSString *)serverAddress
                                             ipv6Enabled:(BOOL)ipv6Enabled;

/// Same as above, additionally excluding the CN routes from a validated
/// CN-bypass artifact (see MWCnBypass) so mainland-China traffic stays on
/// the physical interface. `cnBypass` nil means full-tunnel routing.
/// IPv6 CN routes apply only when `ipv6Enabled` — with IPv6 off the TUN
/// claims no v6 routes, so there is nothing to exclude from.
+ (NEPacketTunnelNetworkSettings *)makeWithServerAddress:(NSString *)serverAddress
                                             ipv6Enabled:(BOOL)ipv6Enabled
                                                cnBypass:(nullable MWCnBypassRoutes *)cnBypass;
@end

NS_ASSUME_NONNULL_END
