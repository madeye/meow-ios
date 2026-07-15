#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

/// Routes parsed from a valid, engaged CN-bypass artifact.
@interface MWCnBypassRoutes : NSObject
@property (nonatomic, readonly) NSArray<NEIPv4Route *> *ipv4Routes;
@property (nonatomic, readonly) NSArray<NEIPv6Route *> *ipv6Routes;
@end

/// Reader for the CN-bypass artifact written by the app's pre-connect probe
/// (`meow_config_cn_bypass_probe` in meow-ios-ffi). The artifact is plain
/// text:
///
///   meow-cn-bypass v1
///   config-sha256 <64 lowercase hex chars>
///   cn-direct <0|1>
///   <one CIDR per line, v4 then v6>
///
/// Deliberately free of engine/FFI dependencies (Foundation + CommonCrypto +
/// NetworkExtension only) so the exact production implementation compiles
/// into the MeowIntegrationTests bundle — no Swift mirror to drift.
@interface MWCnBypass : NSObject

/// Load and validate the artifact. Returns nil — the caller keeps
/// full-tunnel routing — when the artifact is missing, malformed,
/// disengaged (`cn-direct 0`), carries no usable route, or is stale (its
/// config-sha256 doesn't match the current bytes at `configURL`, e.g. the
/// config was edited after the last app-side probe). Validation is strict:
/// one bad CIDR line rejects the whole artifact, because iOS discards the
/// ENTIRE excludedRoutes payload when a single invalid/loopback destination
/// slips in.
+ (nullable MWCnBypassRoutes *)loadFromURL:(NSURL *)artifactURL
                         matchingConfigURL:(NSURL *)configURL;

@end

NS_ASSUME_NONNULL_END
