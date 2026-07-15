#import "MWCnBypass.h"
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <os/log.h>

static NSString *const kArtifactHeader = @"meow-cn-bypass v1";
static NSString *const kShaLinePrefix = @"config-sha256 ";
static NSString *const kDirectLinePrefix = @"cn-direct ";

// The full CN set is ~8k lines / ~150 KB. Anything an order of magnitude
// beyond that is not an artifact this code ever wrote.
static const NSUInteger kMaxArtifactBytes = 4 * 1024 * 1024;

static os_log_t MWCnBypassLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.tangzixiang.meow.PacketTunnel", "cn-bypass");
    });
    return log;
}

@implementation MWCnBypassRoutes {
    NSArray<NEIPv4Route *> *_ipv4Routes;
    NSArray<NEIPv6Route *> *_ipv6Routes;
}

- (instancetype)initWithIPv4Routes:(NSArray<NEIPv4Route *> *)ipv4Routes
                        ipv6Routes:(NSArray<NEIPv6Route *> *)ipv6Routes {
    self = [super init];
    if (self) {
        _ipv4Routes = [ipv4Routes copy];
        _ipv6Routes = [ipv6Routes copy];
    }
    return self;
}

- (NSArray<NEIPv4Route *> *)ipv4Routes {
    return _ipv4Routes;
}

- (NSArray<NEIPv6Route *> *)ipv6Routes {
    return _ipv6Routes;
}

@end

static NSString *MWHexSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static NSString *MWSubnetMaskFromPrefix(unsigned prefix) {
    // Caller guarantees 1 <= prefix <= 32, so the shift is defined.
    uint32_t mask = (uint32_t)(0xFFFFFFFFu << (32 - prefix));
    return [NSString stringWithFormat:@"%u.%u.%u.%u",
                                      (mask >> 24) & 0xFF, (mask >> 16) & 0xFF,
                                      (mask >> 8) & 0xFF, mask & 0xFF];
}

/// Parse one `address/prefix` line into the v4 or v6 route array. Returns NO
/// on anything invalid — including loopback and /0, either of which would
/// make iOS discard the whole excludedRoutes payload or detach the default
/// route.
static BOOL MWAppendRoute(NSString *line,
                          NSMutableArray<NEIPv4Route *> *v4,
                          NSMutableArray<NEIPv6Route *> *v6) {
    NSRange slash = [line rangeOfString:@"/"];
    if (slash.location == NSNotFound || slash.location == 0 ||
        slash.location == line.length - 1) {
        return NO;
    }
    NSString *address = [line substringToIndex:slash.location];
    NSString *prefixText = [line substringFromIndex:slash.location + 1];

    // Strict unsigned parse — reject "24abc", "-1", "".
    NSScanner *scanner = [NSScanner scannerWithString:prefixText];
    int prefix = 0;
    if (![scanner scanInt:&prefix] || !scanner.isAtEnd || prefix <= 0) {
        return NO;
    }

    if ([address containsString:@":"]) {
        struct in6_addr addr6;
        if (inet_pton(AF_INET6, address.UTF8String, &addr6) != 1 || prefix > 128) {
            return NO;
        }
        if (IN6_IS_ADDR_LOOPBACK(&addr6) || IN6_IS_ADDR_UNSPECIFIED(&addr6)) {
            return NO;
        }
        [v6 addObject:[[NEIPv6Route alloc] initWithDestinationAddress:address
                                          networkPrefixLength:@(prefix)]];
        return YES;
    }

    struct in_addr addr4;
    if (inet_pton(AF_INET, address.UTF8String, &addr4) != 1 || prefix > 32) {
        return NO;
    }
    uint32_t host = ntohl(addr4.s_addr);
    if ((host >> 24) == 127 || host == 0) {
        return NO;
    }
    [v4 addObject:[[NEIPv4Route alloc]
        initWithDestinationAddress:address
                        subnetMask:MWSubnetMaskFromPrefix((unsigned)prefix)]];
    return YES;
}

@implementation MWCnBypass

+ (nullable MWCnBypassRoutes *)loadFromURL:(NSURL *)artifactURL
                         matchingConfigURL:(NSURL *)configURL {
    os_log_t log = MWCnBypassLog();

    NSData *artifactData = [NSData dataWithContentsOfURL:artifactURL];
    if (!artifactData) {
        os_log_info(log, "no artifact at %{public}@ — full-tunnel routing",
                    artifactURL.lastPathComponent);
        return nil;
    }
    if (artifactData.length > kMaxArtifactBytes) {
        os_log_error(log, "artifact oversized (%lu bytes) — ignoring",
                     (unsigned long)artifactData.length);
        return nil;
    }
    NSString *artifact = [[NSString alloc] initWithData:artifactData
                                               encoding:NSUTF8StringEncoding];
    if (!artifact) {
        os_log_error(log, "artifact is not UTF-8 — ignoring");
        return nil;
    }

    NSArray<NSString *> *lines = [artifact componentsSeparatedByString:@"\n"];
    if (lines.count < 3 || ![lines[0] isEqualToString:kArtifactHeader] ||
        ![lines[1] hasPrefix:kShaLinePrefix] || ![lines[2] hasPrefix:kDirectLinePrefix]) {
        os_log_error(log, "artifact header malformed — ignoring");
        return nil;
    }

    // Staleness gate: the artifact must have been probed from the exact
    // config bytes this tunnel is about to run. An on-demand start after an
    // unprobed config edit lands here and falls back to full-tunnel routing.
    NSData *configData = [NSData dataWithContentsOfURL:configURL];
    if (!configData) {
        os_log_error(log, "config unreadable at %{public}@ — ignoring artifact",
                     configURL.lastPathComponent);
        return nil;
    }
    NSString *expectedSha = [lines[1] substringFromIndex:kShaLinePrefix.length];
    NSString *actualSha = MWHexSHA256(configData);
    if ([expectedSha caseInsensitiveCompare:actualSha] != NSOrderedSame) {
        os_log_error(log,
                     "artifact is stale (config changed since last probe) — "
                     "full-tunnel routing until the app re-probes");
        return nil;
    }

    NSString *directFlag = [lines[2] substringFromIndex:kDirectLinePrefix.length];
    if (![directFlag isEqualToString:@"1"]) {
        os_log_info(log, "probe verdict: not CN-direct — full-tunnel routing");
        return nil;
    }

    NSMutableArray<NEIPv4Route *> *v4 = [NSMutableArray array];
    NSMutableArray<NEIPv6Route *> *v6 = [NSMutableArray array];
    for (NSUInteger i = 3; i < lines.count; i++) {
        NSString *line = lines[i];
        if (line.length == 0) {
            continue; // trailing newline
        }
        if (!MWAppendRoute(line, v4, v6)) {
            // One bad destination makes iOS throw away the ENTIRE
            // excludedRoutes payload (see the 127/8 lesson in
            // MWTunnelSettings), so reject the whole artifact instead of
            // shipping a route set that silently disables every exclusion.
            os_log_error(log, "invalid CIDR line %lu (%{public}@) — ignoring artifact",
                         (unsigned long)i, line);
            return nil;
        }
    }
    if (v4.count == 0) {
        os_log_error(log, "engaged artifact carries no IPv4 routes — ignoring");
        return nil;
    }

    os_log_info(log, "CN bypass engaged: %lu v4 + %lu v6 excluded routes",
                (unsigned long)v4.count, (unsigned long)v6.count);
    return [[MWCnBypassRoutes alloc] initWithIPv4Routes:v4 ipv6Routes:v6];
}

@end
