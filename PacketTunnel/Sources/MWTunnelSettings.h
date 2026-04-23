#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

@interface MWTunnelSettings : NSObject
+ (NEPacketTunnelNetworkSettings *)makeWithServerAddress:(NSString *)serverAddress;
@end
