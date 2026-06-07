#import "MWPreferences.h"

NSString *const MWPrefKeyMixedPort     = @"com.meow.mixedPort";
NSString *const MWPrefKeyLogLevel      = @"com.meow.logLevel";
NSString *const MWPrefKeyAllowLan      = @"com.meow.allowLan";
NSString *const MWPrefKeyPendingIntent = @"com.meow.pendingIntent";

@implementation MWPreferences

- (instancetype)init {
    self = [super init];
    if (self) {
        _mixedPort  = 7890;
        _logLevel   = @"info";
        _allowLan   = NO;
    }
    return self;
}

+ (instancetype)loadFromDefaults:(NSUserDefaults *)defaults {
    MWPreferences *p = [[MWPreferences alloc] init];
    if ([defaults objectForKey:MWPrefKeyMixedPort])
        p.mixedPort = [defaults integerForKey:MWPrefKeyMixedPort];
    NSString *level = [defaults stringForKey:MWPrefKeyLogLevel];
    p.logLevel = level ?: @"info";
    if ([defaults objectForKey:MWPrefKeyAllowLan])
        p.allowLan = [defaults boolForKey:MWPrefKeyAllowLan];
    return p;
}

@end
