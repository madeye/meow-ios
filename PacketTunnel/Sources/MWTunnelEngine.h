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

/// Stops & restarts the engine + TUN in-process with the same config.
/// Async; no-op if not started or a restart is already in flight (in which
/// case `completion` fires with NO immediately).
- (void)restartWithCompletion:(nullable void (^)(BOOL success))completion;

@property (nonatomic, readonly) BOOL isEngineRunning;
@property (nonatomic, readonly) BOOL tunStarted;

- (NSDictionary *)runDiagnostics;

@end
