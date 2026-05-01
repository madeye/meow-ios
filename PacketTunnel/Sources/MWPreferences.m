#import "MWPreferences.h"

NSString *const MWPrefKeyMixedPort     = @"com.meow.mixedPort";
NSString *const MWPrefKeyDnsServers    = @"com.meow.dnsServers";
NSString *const MWPrefKeyLogLevel      = @"com.meow.logLevel";
NSString *const MWPrefKeyAllowLan      = @"com.meow.allowLan";
NSString *const MWPrefKeyIpv6          = @"com.meow.ipv6";
NSString *const MWPrefKeyPendingIntent = @"com.meow.pendingIntent";

@implementation MWPreferences

- (instancetype)init {
    self = [super init];
    if (self) {
        _mixedPort  = 7890;
        _dnsServers = @"";
        _logLevel   = @"info";
        _allowLan   = NO;
        _ipv6       = NO;
    }
    return self;
}

+ (instancetype)loadFromDefaults:(NSUserDefaults *)defaults {
    MWPreferences *p = [[MWPreferences alloc] init];
    if ([defaults objectForKey:MWPrefKeyMixedPort])
        p.mixedPort = [defaults integerForKey:MWPrefKeyMixedPort];
    NSString *dns = [defaults stringForKey:MWPrefKeyDnsServers];
    p.dnsServers = dns ?: @"";
    NSString *level = [defaults stringForKey:MWPrefKeyLogLevel];
    p.logLevel = level ?: @"info";
    if ([defaults objectForKey:MWPrefKeyAllowLan])
        p.allowLan = [defaults boolForKey:MWPrefKeyAllowLan];
    if ([defaults objectForKey:MWPrefKeyIpv6])
        p.ipv6 = [defaults boolForKey:MWPrefKeyIpv6];
    return p;
}

@end
