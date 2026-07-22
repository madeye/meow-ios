#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "MWDiagnosticsRunner.h"

@interface MWTunnelEngine : NSObject

- (instancetype)initWithPacketFlow:(NEPacketTunnelFlow *)flow;

/// Called on the traffic pump's background queue when consecutive health
/// probes fail (data path is dead). The provider should dispatch recovery
/// to the engine control queue.
@property (nonatomic, copy, nullable) void (^onHealthCheckFailed)(void);

/// Blocking: runs engine + tun2socks start FFI calls. Call on a background queue.
- (BOOL)startWithError:(NSError **)error;

/// Blocking: restarts engine + tun2socks in-place, keeping the TUN interface,
/// the packet read loop, and the writer context alive. Call on the engine
/// control queue.
- (BOOL)restartWithError:(NSError **)error;

/// Blocking: hot-reloads mode/rules/proxies into the running engine — no flow
/// drop, no DNS blackout. On failure the old configuration keeps running
/// untouched. Call on the engine control queue.
- (BOOL)reloadConfigWithError:(NSError **)error;

/// Stops engine, tun2socks, ingress loop, traffic pump.
- (void)stop;

@property (nonatomic, readonly) BOOL isEngineRunning;
@property (nonatomic, readonly) BOOL tunStarted;

- (NSDictionary *)runDiagnostics;

@end
