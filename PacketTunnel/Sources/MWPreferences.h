#pragma once
#import <Foundation/Foundation.h>

extern NSString *const MWPrefKeyMixedPort;
extern NSString *const MWPrefKeyDnsServers;
extern NSString *const MWPrefKeyLogLevel;
extern NSString *const MWPrefKeyAllowLan;
extern NSString *const MWPrefKeyIpv6;
extern NSString *const MWPrefKeyPendingIntent;

@interface MWPreferences : NSObject
@property (nonatomic, assign) NSInteger mixedPort;
@property (nonatomic, copy)   NSString *dnsServers;
@property (nonatomic, copy)   NSString *logLevel;
@property (nonatomic, assign) BOOL allowLan;
@property (nonatomic, assign) BOOL ipv6;
+ (instancetype)loadFromDefaults:(NSUserDefaults *)defaults;
@end
