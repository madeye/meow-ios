#pragma once
#import <Foundation/Foundation.h>

/// Returns a JSON-encodable NSDictionary matching the Swift DiagnosticsReport wire format.
@interface MWDiagnosticsRunner : NSObject
+ (NSDictionary *)runWithEngineRunning:(BOOL)engineRunning tunStarted:(BOOL)tunStarted;
+ (NSDictionary *)runUserRequest:(NSDictionary *)request;
+ (NSInteger)residentMemoryMB;
@end
