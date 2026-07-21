#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "MWDiagnosticsRunner.h"

@interface MWTunnelEngine : NSObject

- (instancetype)initWithPacketFlow:(NEPacketTunnelFlow *)flow;

/// Blocking: runs engine + tun2socks start FFI calls. Call on a background queue.
- (BOOL)startWithError:(NSError **)error;

/// Stops engine, tun2socks, ingress loop, traffic pump.
- (void)stop;

@property (nonatomic, readonly) BOOL isEngineRunning;
@property (nonatomic, readonly) BOOL tunStarted;

- (NSDictionary *)runDiagnostics;

@end
