#import "MWTunnelEngine.h"
#import "MWAppGroup.h"
#import "MWPreferences.h"
#import "MWPacketWriter.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "mihomo_core.h"
#import <stdatomic.h>
#import <os/log.h>
#import <mach/mach.h>
#import <malloc/malloc.h>

static os_log_t gLog;

@implementation MWTunnelEngine {
    NEPacketTunnelFlow *_flow;
    MWPacketWriter *_writer;
    void *_writerCtx;          // CFRetained pointer passed to Rust

    BOOL _started;
    _Atomic BOOL _ingressRunning;
    _Atomic int64_t _ingressPackets;
    _Atomic BOOL _restarting;

    dispatch_source_t _trafficTimer;
    int64_t _lastUp;
    int64_t _lastDown;
    NSTimeInterval _lastTime;
    int _pumpTick;
}

+ (void)initialize {
    if (self == [MWTunnelEngine class]) {
        gLog = os_log_create("io.github.madeye.meow.PacketTunnel", "engine");
    }
}

- (instancetype)initWithPacketFlow:(NEPacketTunnelFlow *)flow {
    self = [super init];
    if (self) {
        _flow = flow;
        atomic_init(&_ingressRunning, NO);
        atomic_init(&_ingressPackets, 0);
        atomic_init(&_restarting, NO);
    }
    return self;
}

// MARK: - Start

- (BOOL)startWithError:(NSError **)error {
    if (_started) return YES;
    _started = YES;

    os_log_error(gLog, "engine: startWithError entry");

    NSString *homeDir = [MWAppGroup containerURL].path;
    MWPreferences *prefs = [MWPreferences loadFromDefaults:[MWAppGroup defaults]];

    if (![self writeEffectiveConfigWithPrefs:prefs error:error]) {
        _started = NO;
        return NO;
    }

    meow_core_init();
    meow_core_set_home_dir(homeDir.UTF8String);

    NSString *configPath = [MWAppGroup effectiveConfigURL].path;
    int rc = meow_engine_start(configPath.UTF8String);
    if (rc != 0) {
        NSString *msg = [self lastRustError] ?: @"engine start failed";
        if (error) *error = [NSError errorWithDomain:@"MWTunnelEngine"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
        _started = NO;
        return NO;
    }

    MWPacketWriter *writer = [[MWPacketWriter alloc] initWithFlow:_flow];
    _writer    = writer;
    _writerCtx = (void *)CFBridgingRetain(writer);

    rc = meow_tun_start(_writerCtx, meowPacketWriterCB);
    if (rc != 0) {
        NSString *msg = [self lastRustError] ?: @"tun start failed";
        if (error) *error = [NSError errorWithDomain:@"MWTunnelEngine"
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
        CFBridgingRelease(_writerCtx);
        _writerCtx = NULL;
        _writer    = nil;
        meow_engine_stop();
        _started = NO;
        return NO;
    }
    _tunStarted = YES;

    [self startIngressLoop];
    [self startTrafficPump];
    return YES;
}

// MARK: - Stop

- (void)stop {
    if (!_started) return;
    _started = NO;

    atomic_store_explicit(&_ingressRunning, NO, memory_order_relaxed);

    [self stopTrafficPump];

    meow_tun_stop();
    _tunStarted = NO;
    meow_engine_stop();

    if (_writerCtx) {
        CFBridgingRelease(_writerCtx);
        _writerCtx = NULL;
    }
    _writer = nil;
}

// MARK: - Engine state

- (BOOL)isEngineRunning {
    return meow_engine_is_running() != 0;
}

@synthesize tunStarted = _tunStarted;

// MARK: - Diagnostics

- (NSDictionary *)runDiagnostics {
    return [MWDiagnosticsRunner runWithEngineRunning:self.isEngineRunning
                                          tunStarted:self.tunStarted];
}

// MARK: - Ingress loop

- (void)startIngressLoop {
    atomic_store_explicit(&_ingressRunning, YES, memory_order_relaxed);
    [self readNextPackets];
}

- (void)readNextPackets {
    if (!atomic_load_explicit(&_ingressRunning, memory_order_relaxed)) return;
    __weak __typeof__(self) weak = self;
    [_flow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets,
                                              NSArray<NSNumber *> *protocols) {
        @autoreleasepool {
            __strong __typeof__(weak) self = weak;
            if (!self) return;
            if (!atomic_load_explicit(&self->_ingressRunning, memory_order_relaxed)) return;
            for (NSData *pkt in packets) {
                meow_tun_ingest((const uint8_t *)pkt.bytes, (uintptr_t)pkt.length);
                atomic_fetch_add_explicit(&self->_ingressPackets, 1, memory_order_relaxed);
            }
            os_log_debug(gLog, "ingress batch: %zu packets", packets.count);
            [self readNextPackets];
        }
    }];
}

// MARK: - Traffic pump (500 ms interval)

- (void)startTrafficPump {
    os_log_error(gLog, "engine: startTrafficPump entry");
    _lastUp   = 0;
    _lastDown = 0;
    _lastTime = [[NSDate date] timeIntervalSinceReferenceDate];

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    _trafficTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_trafficTimer,
        dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        500 * NSEC_PER_MSEC,
        10  * NSEC_PER_MSEC);

    __weak __typeof__(self) weak = self;
    dispatch_source_set_event_handler(_trafficTimer, ^{
        [weak emitTrafficSnapshot];
    });
    dispatch_resume(_trafficTimer);
}

- (void)stopTrafficPump {
    if (_trafficTimer) {
        dispatch_source_cancel(_trafficTimer);
        _trafficTimer = nil;
    }
}

- (void)emitTrafficSnapshot {
    os_log_error(gLog, "engine: emitTrafficSnapshot tick=%d", _pumpTick);
    int64_t up = 0, down = 0;
    meow_engine_traffic(&up, &down);

    NSTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
    double dt = MAX(0.001, now - _lastTime);
    int64_t upRate   = (int64_t)((double)(up   - _lastUp)   / dt);
    int64_t downRate = (int64_t)((double)(down - _lastDown) / dt);
    _lastUp = up; _lastDown = down; _lastTime = now;

    int64_t ingressPkts = atomic_load_explicit(&_ingressPackets, memory_order_relaxed);
    int64_t egressPkts  = _writer.egressPackets;

    // phys_footprint is what jetsam measures — not resident_size.
    struct task_vm_info vmi = {0};
    mach_msg_type_number_t vmic = TASK_VM_INFO_COUNT;
    NSInteger footprintMB = -1;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &vmic) == KERN_SUCCESS) {
        footprintMB = (NSInteger)(vmi.phys_footprint / (1024 * 1024));
    }

    malloc_statistics_t ms = {0};
    malloc_zone_statistics(malloc_default_zone(), &ms);
    NSInteger heapUsedKB = (NSInteger)(ms.size_in_use / 1024);
    NSInteger heapFreeKB = (NSInteger)((ms.size_allocated - ms.size_in_use) / 1024);
    int64_t tcpConns = meow_active_tcp_conns();

    NSString *memline = [NSString stringWithFormat:
        @"tick=%d footprint=%ldMB heap_used=%ldKB heap_free=%ldKB tcp_conns=%lld "
         "up=%lldB/s down=%lldB/s totalUp=%lldB totalDown=%lldB\n",
        _pumpTick, (long)footprintMB, (long)heapUsedKB, (long)heapFreeKB, tcpConns,
        upRate, downRate, up, down];
    os_log_error(gLog, "memstats %{public}@", memline);

    // Also write to a file in the App Group container so the Mac can poll it
    // via `xcrun devicectl device copy from --domain-type appGroupDataContainer`.
    NSURL *statsURL = [[MWAppGroup containerURL] URLByAppendingPathComponent:@"memstats.txt"];
    [memline writeToURL:statsURL atomically:NO encoding:NSUTF8StringEncoding error:nil];

    _pumpTick++;
    if (_pumpTick % 10 == 0) {
        malloc_zone_pressure_relief(NULL, 0);
    }

    NSTimeInterval epoch = now + NSTimeIntervalSince1970;
    NSDictionary *snapshot = @{
        @"uploadBytes":    @(up),
        @"downloadBytes":  @(down),
        @"uploadRate":     @(upRate),
        @"downloadRate":   @(downRate),
        @"ingressPackets": @(ingressPkts),
        @"egressPackets":  @(egressPkts),
        @"timestamp":      @(epoch),
        @"footprintMB":    @(footprintMB),
        @"heapUsedKB":     @(heapUsedKB),
        @"heapFreeKB":     @(heapFreeKB),
        @"tcpConns":       @(tcpConns),
        @"pumpTick":       @(_pumpTick),
    };

    NSError *err = nil;
    if (![MWSharedStore writeTraffic:snapshot error:&err]) {
        os_log_error(gLog, "traffic write failed: %{public}@", err);
        return;
    }
    [MWDarwinBridge post:MWNotificationTraffic];
}

// MARK: - Engine restart

- (void)restartWithCompletion:(void (^)(BOOL))completion {
    if (!_started) {
        if (completion) completion(NO);
        return;
    }
    if (atomic_exchange(&_restarting, YES)) {
        os_log_info(gLog, "restart: already in flight, skipping");
        if (completion) completion(NO);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [self performEngineRestart];
        if (completion) completion(ok);
    });
}

- (BOOL)performEngineRestart {
    os_log_info(gLog, "restart: stopping tun + engine");

    meow_tun_stop();
    _tunStarted = NO;
    meow_engine_stop();

    if (_writerCtx) {
        CFBridgingRelease(_writerCtx);
        _writerCtx = NULL;
    }
    _writer = nil;

    // Let Rust async tasks drain before rebinding ports.
    [NSThread sleepForTimeInterval:0.3];
    malloc_zone_pressure_relief(NULL, 0);

    if (!_started) {
        os_log_info(gLog, "restart: engine was stopped externally, aborting");
        atomic_store_explicit(&_restarting, NO, memory_order_relaxed);
        return NO;
    }

    MWPreferences *prefs = [MWPreferences loadFromDefaults:[MWAppGroup defaults]];
    NSError *err = nil;
    if (![self writeEffectiveConfigWithPrefs:prefs error:&err]) {
        os_log_error(gLog, "restart: config write failed: %{public}@", err);
        atomic_store_explicit(&_restarting, NO, memory_order_relaxed);
        return NO;
    }

    NSString *configPath = [MWAppGroup effectiveConfigURL].path;
    int rc = meow_engine_start(configPath.UTF8String);
    if (rc != 0) {
        os_log_error(gLog, "restart: engine start failed: %{public}@",
                     [self lastRustError]);
        atomic_store_explicit(&_restarting, NO, memory_order_relaxed);
        return NO;
    }

    MWPacketWriter *writer = [[MWPacketWriter alloc] initWithFlow:_flow];
    _writer    = writer;
    _writerCtx = (void *)CFBridgingRetain(writer);

    rc = meow_tun_start(_writerCtx, meowPacketWriterCB);
    if (rc != 0) {
        os_log_error(gLog, "restart: tun start failed: %{public}@",
                     [self lastRustError]);
        CFBridgingRelease(_writerCtx);
        _writerCtx = NULL;
        _writer    = nil;
        meow_engine_stop();
        atomic_store_explicit(&_restarting, NO, memory_order_relaxed);
        return NO;
    }
    _tunStarted = YES;

    os_log_info(gLog, "restart: complete");
    atomic_store_explicit(&_restarting, NO, memory_order_relaxed);
    return YES;
}

// MARK: - Config patching

- (BOOL)writeEffectiveConfigWithPrefs:(MWPreferences *)prefs error:(NSError **)error {
    NSString *source = [NSString stringWithContentsOfURL:[MWAppGroup configURL]
                                                encoding:NSUTF8StringEncoding
                                                   error:error];
    if (!source) return NO;

    const char *src = source.UTF8String;
    int needed = meow_patch_config(src, (int)prefs.mixedPort, NULL, 0);
    if (needed < 0) {
        NSString *msg = [self lastRustError] ?: @"config patch failed";
        if (error) *error = [NSError errorWithDomain:@"MWTunnelEngine"
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }

    char *buf = (char *)malloc((size_t)(needed + 1));
    meow_patch_config(src, (int)prefs.mixedPort, buf, needed + 1);
    NSString *patched = [NSString stringWithUTF8String:buf];
    free(buf);

    NSURL *dst = [MWAppGroup effectiveConfigURL];
    NSURL *dir = [dst URLByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [patched writeToURL:dst atomically:YES encoding:NSUTF8StringEncoding error:error];
}

// MARK: - Helpers

- (NSString *)lastRustError {
    const char *p = meow_core_last_error();
    return (p && p[0]) ? [NSString stringWithUTF8String:p] : nil;
}

@end
