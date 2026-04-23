#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, MWNotification) {
    MWNotificationCommand,
    MWNotificationState,
    MWNotificationTraffic,
};

@interface MWDarwinObserver : NSObject
- (void)stop;
@end

@interface MWDarwinBridge : NSObject
+ (void)post:(MWNotification)notification;
+ (MWDarwinObserver *)observe:(MWNotification)notification handler:(dispatch_block_t)handler;
+ (void)remove:(MWDarwinObserver *)observer;
@end
