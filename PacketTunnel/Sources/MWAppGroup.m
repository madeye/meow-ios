#import "MWAppGroup.h"

// Authored identifier as declared in PacketTunnel.entitlements. App Store
// builds strip the embedded provisioning profile, so `+identifier` returns
// this constant — fine because Apple signs with the authoring team and the
// entitlement is preserved verbatim. Sideloaders (AltStore / SideStore) keep
// the embedded.mobileprovision and rewrite the app-group entitlement to
// append the installer's team prefix; `+identifier` reads that at runtime.
static NSString *const MWAppGroupAuthoredIdentifier = @"group.io.github.madeye.meow";

NSString *const MWAppGroupIdentifier = @"group.io.github.madeye.meow";

@implementation MWAppGroup

+ (NSString *)identifier {
    static NSString *resolved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        resolved = MWAppGroupAuthoredIdentifier;
        NSURL *url = [[NSBundle mainBundle] URLForResource:@"embedded" withExtension:@"mobileprovision"];
        if (url == nil) { return; }
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data == nil) { return; }
        NSString *ascii = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        if (ascii == nil) { return; }
        NSRange start = [ascii rangeOfString:@"<plist"];
        if (start.location == NSNotFound) { return; }
        NSRange end = [ascii rangeOfString:@"</plist>" options:0
                                    range:NSMakeRange(NSMaxRange(start), ascii.length - NSMaxRange(start))];
        if (end.location == NSNotFound) { return; }
        NSString *slice = [ascii substringWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
        NSData *plistData = [slice dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id parsed = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:&error];
        if (![parsed isKindOfClass:[NSDictionary class]]) { return; }
        NSDictionary *entitlements = parsed[@"Entitlements"];
        if (![entitlements isKindOfClass:[NSDictionary class]]) { return; }
        NSArray *groups = entitlements[@"com.apple.security.application-groups"];
        if (![groups isKindOfClass:[NSArray class]] || groups.count == 0) { return; }
        id first = groups.firstObject;
        if ([first isKindOfClass:[NSString class]]) {
            resolved = [first copy];
        }
    });
    return resolved;
}

+ (NSURL *)containerURL {
    NSString *identifier = [self identifier];
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:identifier];
    NSAssert(url, @"App Group container unavailable — entitlement missing '%@'", identifier);
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
    NSString *identifier = [self identifier];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:identifier];
    NSAssert(d, @"Shared UserDefaults unavailable for suite '%@'", identifier);
    return d;
}

@end
