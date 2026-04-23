#pragma once
#import <Foundation/Foundation.h>

typedef void (^MWIntentHandler)(NSDictionary *intent);

@interface MWIPCListener : NSObject
- (instancetype)initWithHandler:(MWIntentHandler)handler;
- (void)start;
- (void)stop;
@end
