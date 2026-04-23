#import "MWAppGroup.h"

NSString *const MWAppGroupIdentifier = @"group.io.github.madeye.meow";

@implementation MWAppGroup

+ (NSURL *)containerURL {
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:MWAppGroupIdentifier];
    NSAssert(url, @"App Group container unavailable — entitlement missing '%@'", MWAppGroupIdentifier);
    return url;
}

+ (NSURL *)configURL {
    return [[self containerURL] URLByAppendingPathComponent:@"config.yaml"];
}

+ (NSURL *)effectiveConfigURL {
    return [[self containerURL] URLByAppendingPathComponent:@"effective-config.yaml"];
}

+ (NSURL *)stateURL {
    return [[self containerURL] URLByAppendingPathComponent:@"state.json"];
}

+ (NSURL *)trafficURL {
    return [[self containerURL] URLByAppendingPathComponent:@"traffic.json"];
}

+ (NSUserDefaults *)defaults {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:MWAppGroupIdentifier];
    NSAssert(d, @"Shared UserDefaults unavailable for suite '%@'", MWAppGroupIdentifier);
    return d;
}

@end
