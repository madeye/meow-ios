#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "MWDiagnosticsRunner.h"

@interface MWTunnelEngine : NSObject

- (instancetype)initWithPacketFlow:(NEPacketTunnelFlow *)flow;

/// Blocking: runs engine + tun2socks start FFI calls. Call on a background queue.
- (BOOL)startWithError:(NSError **)error;

/// Blocking: restarts engine + tun2socks while preserving the packet read loop.
- (BOOL)restartWithError:(NSError **)error;

/// Stops engine, tun2socks, ingress loop, traffic pump.
- (void)stop;

/// Blocking end-to-end data-path probe: injects a synthetic in-TUN DNS query
/// and waits (≤ timeoutMs) for its reply to traverse the full ingress → lwip
/// → meow-dns → egress pipeline. YES = the path is demonstrably live; NO =
/// wedged, not started, or timed out — restart-worthy. Call on the engine
/// control queue, never on a runtime callback thread.
- (BOOL)isDataPathHealthyWithTimeoutMs:(int32_t)timeoutMs;

@property (nonatomic, readonly) BOOL isEngineRunning;
@property (nonatomic, readonly) BOOL tunStarted;

- (NSDictionary *)runDiagnostics;

@end
