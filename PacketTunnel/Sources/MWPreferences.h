#pragma once
#import <Foundation/Foundation.h>

// keep in sync with MeowShared/Sources/MeowModels/Preferences.swift PreferenceKey.*
extern NSString *const MWPrefKeyMixedPort;
extern NSString *const MWPrefKeyLogLevel;
extern NSString *const MWPrefKeyAllowLan;
extern NSString *const MWPrefKeyPendingIntent;

@interface MWPreferences : NSObject
@property (nonatomic, assign) NSInteger mixedPort;
@property (nonatomic, copy)   NSString *logLevel;
@property (nonatomic, assign) BOOL allowLan;
+ (instancetype)loadFromDefaults:(NSUserDefaults *)defaults;
@end
