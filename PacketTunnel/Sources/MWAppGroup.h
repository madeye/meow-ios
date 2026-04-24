#pragma once
#import <Foundation/Foundation.h>

extern NSString *const MWAppGroupIdentifier;

@interface MWAppGroup : NSObject
@property (class, nonatomic, readonly) NSString *identifier;
@property (class, nonatomic, readonly) NSURL *containerURL;
@property (class, nonatomic, readonly) NSURL *configURL;
@property (class, nonatomic, readonly) NSURL *effectiveConfigURL;
@property (class, nonatomic, readonly) NSURL *stateURL;
@property (class, nonatomic, readonly) NSURL *trafficURL;
@property (class, nonatomic, readonly) NSUserDefaults *defaults;
@end
