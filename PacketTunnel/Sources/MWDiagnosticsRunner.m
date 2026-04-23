#import "MWDiagnosticsRunner.h"
#import "mihomo_core.h"
#import <mach/mach.h>

static const NSInteger kMemPassLimitMB = 14;
static const NSInteger kMemFailLimitMB = 15;

static NSDictionary *pass(void) {
    return @{@"pass": @YES, @"reason": @""};
}

static NSDictionary *fail(NSString *reason) {
    return @{@"pass": @NO, @"reason": reason ?: @""};
}

static NSString *lastRustError(NSString *fallback) {
    const char *p = meow_core_last_error();
    if (p) {
        NSString *s = [NSString stringWithUTF8String:p];
        if (s.length) {
            // Strip newlines and parens to keep PRD §4.4 label grammar clean
            NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
            for (NSUInteger i = 0; i < s.length; i++) {
                unichar c = [s characterAtIndex:i];
                if (c == '\n' || c == '\r') { [out appendString:@" "]; continue; }
                if (c == '(' || c == ')') continue;
                [out appendFormat:@"%C", c];
            }
            NSString *trimmed = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length) return trimmed;
        }
    }
    return fallback;
}

@implementation MWDiagnosticsRunner

+ (NSDictionary *)runWithEngineRunning:(BOOL)engineRunning tunStarted:(BOOL)tunStarted {
    return @{
        @"tunExists":  [self tunExists:engineRunning tunStarted:tunStarted],
        @"dnsOk":      [self dnsOk],
        @"tcpProxyOk": [self tcpProxyOk],
        @"http204Ok":  [self http204Ok],
        @"memOk":      [self memOk],
    };
}

+ (NSDictionary *)tunExists:(BOOL)engineRunning tunStarted:(BOOL)tunStarted {
    if (!engineRunning) return fail(@"engine_not_running");
    if (!tunStarted)    return fail(@"tun_not_started");
    return pass();
}

+ (NSDictionary *)dnsOk {
    char buf[512] = {0};
    int rc = meow_engine_test_dns("example.com", 2000, buf, sizeof(buf));
    if (rc < 0) return fail(lastRustError(@"resolve_failed"));
    NSString *answer = [NSString stringWithUTF8String:buf];
    if (!answer.length) return fail(@"empty_answer");
    return pass();
}

+ (NSDictionary *)tcpProxyOk {
    int64_t ms = 0;
    int rc = meow_engine_test_direct_tcp("1.1.1.1", 443, 3000, &ms);
    if (rc < 0) return fail(lastRustError(@"connect_failed"));
    return pass();
}

+ (NSDictionary *)http204Ok {
    int32_t status = 0;
    int64_t ms = 0;
    int rc = meow_engine_test_proxy_http("http://www.gstatic.com/generate_204", 5000, &status, &ms);
    if (rc < 0) return fail(lastRustError(@"request_failed"));
    if (status != 204) return fail([NSString stringWithFormat:@"status=%d", status]);
    return pass();
}

+ (NSDictionary *)memOk {
    NSInteger mb = [self residentMemoryMB];
    if (mb < 0) return fail(@"task_info_failed");
    if (mb <= kMemPassLimitMB) return pass();
    return fail([NSString stringWithFormat:@"mem=%ldmb>=%ldmb", (long)mb, (long)kMemFailLimitMB]);
}

+ (NSInteger)residentMemoryMB {
    struct task_vm_info info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t rc = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &count);
    if (rc != KERN_SUCCESS) return -1;
    return (NSInteger)(info.phys_footprint / (1024 * 1024));
}

// MARK: - User-initiated diagnostics (T4.10)

+ (NSDictionary *)runUserRequest:(NSDictionary *)request {
    if (request[@"proxyHttp"]) {
        NSDictionary *args = request[@"proxyHttp"];
        NSString *url = args[@"url"] ?: @"";
        int32_t timeoutMs = [args[@"timeoutMs"] intValue] ?: 5000;
        return [self userProxyHttp:url timeoutMs:timeoutMs];
    }
    if (request[@"dns"]) {
        NSDictionary *args = request[@"dns"];
        NSString *host = args[@"host"] ?: @"";
        int32_t timeoutMs = [args[@"timeoutMs"] intValue] ?: 2000;
        return [self userDns:host timeoutMs:timeoutMs];
    }
    return @{@"success": @NO, @"errorReason": @"unknown_request"};
}

+ (NSDictionary *)userProxyHttp:(NSString *)url timeoutMs:(int32_t)timeoutMs {
    int32_t status = 0;
    int64_t ms = 0;
    int rc = meow_engine_test_proxy_http(url.UTF8String, timeoutMs, &status, &ms);
    if (rc < 0) {
        return @{@"success": @NO, @"errorReason": lastRustError(@"request_failed")};
    }
    return @{@"success": @YES, @"latencyMs": @(ms), @"httpStatus": @(status)};
}

+ (NSDictionary *)userDns:(NSString *)host timeoutMs:(int32_t)timeoutMs {
    char buf[512] = {0};
    NSTimeInterval before = [[NSDate date] timeIntervalSinceReferenceDate];
    int rc = meow_engine_test_dns(host.UTF8String, timeoutMs, buf, sizeof(buf));
    int64_t ms = (int64_t)(([[NSDate date] timeIntervalSinceReferenceDate] - before) * 1000);
    if (rc < 0) {
        return @{@"success": @NO, @"errorReason": lastRustError(@"resolve_failed")};
    }
    NSString *answer = [NSString stringWithUTF8String:buf];
    if (!answer.length) {
        return @{@"success": @NO, @"errorReason": @"empty_answer"};
    }
    return @{@"success": @YES, @"latencyMs": @(ms)};
}

@end
