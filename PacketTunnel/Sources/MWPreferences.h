#pragma once
#import <Foundation/Foundation.h>

// keep in sync with MeowShared/Sources/MeowModels/Preferences.swift PreferenceKey.*
extern NSString *const MWPrefKeyMixedPort;
extern NSString *const MWPrefKeyLogLevel;
extern NSString *const MWPrefKeyAllowLan;
extern NSString *const MWPrefKeyBlockHTTP3;
extern NSString *const MWPrefKeyIPv6Enabled;
extern NSString *const MWPrefKeyPendingIntent;

@interface MWPreferences : NSObject
@property (nonatomic, assign) NSInteger mixedPort;
@property (nonatomic, copy)   NSString *logLevel;
@property (nonatomic, assign) BOOL allowLan;
@property (nonatomic, assign) BOOL blockHTTP3;
@property (nonatomic, assign) BOOL ipv6Enabled;
+ (instancetype)loadFromDefaults:(NSUserDefaults *)defaults;
@end
