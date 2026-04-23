#import "MWDarwinBridge.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *nameFor(MWNotification n) {
    switch (n) {
        case MWNotificationCommand: return @"com.meow.vpn.command";
        case MWNotificationState:   return @"com.meow.vpn.state";
        case MWNotificationTraffic: return @"com.meow.vpn.traffic";
    }
}

@interface MWDarwinObserver ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) dispatch_block_t handler;
@property (nonatomic, assign) BOOL active;
@end

@implementation MWDarwinObserver

- (instancetype)initWithName:(NSString *)name handler:(dispatch_block_t)handler {
    self = [super init];
    if (self) {
        _name    = name;
        _handler = handler;
    }
    return self;
}

- (void)register {
    void *ctx = (__bridge void *)self;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ctx,
        darwinCallback,
        (__bridge CFStringRef)_name,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    _active = YES;
}

static void darwinCallback(CFNotificationCenterRef c, void *observer,
                            CFNotificationName name, const void *obj,
                            CFDictionaryRef info) {
    MWDarwinObserver *this = (__bridge MWDarwinObserver *)observer;
    if (this.handler) this.handler();
}

- (void)stop {
    if (!_active) return;
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge void *)self,
        (__bridge CFStringRef)_name,
        NULL
    );
    _active = NO;
}

- (void)dealloc { [self stop]; }

@end

@implementation MWDarwinBridge

+ (void)post:(MWNotification)notification {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFNotificationName)nameFor(notification),
        NULL, NULL, true
    );
}

+ (MWDarwinObserver *)observe:(MWNotification)notification handler:(dispatch_block_t)handler {
    MWDarwinObserver *obs = [[MWDarwinObserver alloc] initWithName:nameFor(notification)
                                                           handler:handler];
    [obs register];
    return obs;
}

+ (void)remove:(MWDarwinObserver *)observer {
    [observer stop];
}

@end
