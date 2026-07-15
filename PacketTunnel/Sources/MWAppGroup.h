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
/// CN-bypass artifact written by the app's pre-connect probe
/// (meow_config_cn_bypass_probe); consumed at tunnel start to exclude CN
/// routes from the TUN. Keep in sync with AppGroup.cnBypassURL (Swift).
@property (class, nonatomic, readonly) NSURL *cnBypassURL;
@property (class, nonatomic, readonly) NSUserDefaults *defaults;
@end
