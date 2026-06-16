#import "MWTunnelEngine.h"
#import "MWAppGroup.h"
#import "MWPreferences.h"
#import "MWPacketWriter.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "MWEngineLog.h"
#import "meow_core.h"
#import <stdatomic.h>
#import <os/log.h>
#import <mach/mach.h>
#import <malloc/malloc.h>

static os_log_t gLog;

// Phys-footprint soft cap: jetsam on the NE extension hits around 50 MiB on
// recent iOS. When footprint reaches this threshold we nudge the allocator to
// return free pages to the OS rather than restarting the engine — a restart
// disrupts active connections and resets in-memory state for marginal gain.
static const NSInteger kSoftCapFootprintMB    = 35;
static const NSTimeInterval kReliefCooldownS  = 60.0;

// Proactive-reclaim trigger for a TCP teardown burst. When a batch of flows
// closes together — network handoff (Wi-Fi↔cellular), reconnect, or the app
// dropping a page full of connections — their relay buffers (owned by meow's
// `copy_bidirectional_buf`) free at once. That is the peak-fragmentation
// moment: lots of just-freed pages the allocator is still holding. Returning
// them now, rather than waiting up to the soft-cap watchdog, keeps the
// footprint low while the extension is awake. We trigger off a drop in
// `tcp_conns` (a clean integer count) rather than malloc's free-heap figure,
// which includes non-resident reserved address space and reads larger than the
// physical footprint itself (~21 MB free at a 12 MB footprint), so it can't
// gate a reclaim. The short cooldown keeps normal open/close churn from
// thrashing the allocator.
static const int64_t kTeardownBurstFlows       = 16;
static const NSTimeInterval kTeardownCooldownS = 5.0;

@implementation MWTunnelEngine {
    NEPacketTunnelFlow *_flow;
    MWPacketWriter *_writer;
    void *_writerCtx;          // CFRetained pointer passed to Rust

    BOOL _started;
    _Atomic BOOL _ingressRunning;
    // Bumped on every suspend/stop. A readPackets completion handler captures
    // the epoch when it arms and drops itself if the epoch advanced in the
    // meantime — so an in-flight handler from a superseded suspend/resume
    // generation can neither ingest into the new tun2socks instance nor re-arm
    // a second concurrent read chain.
    _Atomic uint64_t _ingressEpoch;
    _Atomic int64_t _ingressPackets;
    dispatch_source_t _trafficTimer;
    int64_t _lastUp;
    int64_t _lastDown;
    NSTimeInterval _lastTime;
    int _pumpTick;
    NSTimeInterval _lastReliefAttempt;  // CFAbsoluteTime; 0 = never
    int64_t _lastTcpConns;              // prev snapshot's tcp_conns, for teardown-burst detection
    NSTimeInterval _lastTeardownRelief; // CFAbsoluteTime; 0 = never
}

+ (void)initialize {
    if (self == [MWTunnelEngine class]) {
        gLog = os_log_create("com.tangzixiang.meow.PacketTunnel", "engine");
    }
}

- (instancetype)initWithPacketFlow:(NEPacketTunnelFlow *)flow {
    self = [super init];
    if (self) {
        _flow = flow;
        atomic_init(&_ingressRunning, NO);
        atomic_init(&_ingressEpoch, 0);
        atomic_init(&_ingressPackets, 0);
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

    // Set the home dir BEFORE patching the config: meow_patch_config mints the
    // REST-API port + secret into <home>/api-credentials.json, and HOME_DIR
    // must already point at the App Group container or the credentials fall
    // back to an ephemeral pair the app can't read. meow_core_init / set_home
    // are independent of the engine and safe to run this early.
    meow_core_init();
    meow_core_set_home_dir(homeDir.UTF8String);

    if (![self writeEffectiveConfigWithPrefs:prefs error:error]) {
        _started = NO;
        return NO;
    }

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

    // Apply the Block HTTP/3 (QUIC) toggle before starting the tun. The Rust
    // setter persists in tun2socks static state, so a single pre-start call
    // covers both the initial meow_tun_start below and any later -resumeTun.
    // When the toggle is off this passes 0, which is the engine's default —
    // behavior is unchanged.
    meow_tun_set_block_http3(prefs.blockHTTP3 ? 1 : 0);

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
    atomic_fetch_add_explicit(&_ingressEpoch, 1, memory_order_relaxed);

    [self stopTrafficPump];

    // BLOCKING stop: wait for the tun2socks run task — and its egress callback
    // loop — to fully terminate before releasing the writer ctx below.
    // meow_tun_stop() is fire-and-forget, so CFBridgingRelease-ing the
    // CFBridgingRetain'd writer right after it returned could free the object
    // while the still-draining egress task calls meowPacketWriterCB on it: a
    // use-after-free. meow_tun_stop_blocking() joins the run task first.
    meow_tun_stop_blocking();
    _tunStarted = NO;
    meow_engine_stop();

    if (_writerCtx) {
        CFBridgingRelease(_writerCtx);
        _writerCtx = NULL;
    }
    _writer = nil;
}

// MARK: - Suspend / resume tun2socks

- (void)suspendTun {
    if (!_tunStarted) return;

    atomic_store_explicit(&_ingressRunning, NO, memory_order_relaxed);
    atomic_fetch_add_explicit(&_ingressEpoch, 1, memory_order_relaxed);
    [self stopTrafficPump];

    // Fire-and-forget here (unlike -stop): the writer ctx is NOT released on
    // suspend — it is reused by the following -resumeTun, whose meow_tun_start
    // awaits the previous teardown via run_handle_slot — so there is no ctx to
    // free underneath the egress task and no UAF window.
    meow_tun_stop();
    _tunStarted = NO;

    os_log_info(gLog, "engine: tun suspended (engine still running)");
    MWEngineLog(MWLogInfo, @"NE: tun suspended (engine still running)");
}

- (void)resumeTun {
    if (_tunStarted) return;
    if (!_started) return;

    int rc = meow_tun_start(_writerCtx, meowPacketWriterCB);
    if (rc != 0) {
        os_log_error(gLog, "engine: tun resume failed: %{public}@",
                     [self lastRustError] ?: @"unknown");
        MWEngineLogf(MWLogError, @"NE: tun resume failed: %@",
                     [self lastRustError] ?: @"unknown");
        return;
    }
    _tunStarted = YES;

    [self startIngressLoop];
    [self startTrafficPump];
    os_log_info(gLog, "engine: tun resumed");
    MWEngineLog(MWLogInfo, @"NE: tun resumed");
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
    uint64_t epoch = atomic_load_explicit(&_ingressEpoch, memory_order_relaxed);
    __weak __typeof__(self) weak = self;
    [_flow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets,
                                              NSArray<NSNumber *> *protocols) {
        @autoreleasepool {
            __strong __typeof__(weak) self = weak;
            if (!self) return;
            if (!atomic_load_explicit(&self->_ingressRunning, memory_order_relaxed)) return;
            // Epoch guard: a suspend/stop after this read was armed bumps
            // _ingressEpoch. Drop the stale completion so an in-flight handler
            // from a superseded generation neither ingests into the new
            // tun2socks instance nor re-arms a second concurrent readPackets
            // chain (NEPacketTunnelFlow expects one outstanding read at a time).
            if (atomic_load_explicit(&self->_ingressEpoch, memory_order_relaxed) != epoch) return;
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
    os_log_debug(gLog, "engine: startTrafficPump entry");
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
    os_log_debug(gLog, "engine: emitTrafficSnapshot tick=%d", _pumpTick);
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
    os_log_debug(gLog, "memstats %{public}@", memline);

    // Also write to a file in the App Group container so the Mac can poll it
    // via `xcrun devicectl device copy from --domain-type appGroupDataContainer`.
    NSURL *statsURL = [[MWAppGroup containerURL] URLByAppendingPathComponent:@"memstats.txt"];
    [memline writeToURL:statsURL atomically:NO encoding:NSUTF8StringEncoding error:nil];

    _pumpTick++;
    if (_pumpTick % 10 == 0) {
        malloc_zone_pressure_relief(NULL, 0);
    }

    // Proactive reclaim on a TCP teardown burst (see kTeardownBurstFlows). A
    // sharp drop in live connections means a batch of relay buffers just
    // freed; return those pages immediately rather than waiting for the next
    // periodic relief or the soft-cap watchdog. The cooldown bounds this to at
    // most one extra relief per kTeardownCooldownS so steady churn can't thrash
    // the allocator.
    if (_lastTcpConns - tcpConns >= kTeardownBurstFlows &&
        (now - _lastTeardownRelief) >= kTeardownCooldownS) {
        os_log_info(gLog,
                    "teardown burst: tcp_conns %lld→%lld, returning free pages",
                    _lastTcpConns, tcpConns);
        malloc_zone_pressure_relief(NULL, 0);
        _lastTeardownRelief = now;
    }
    _lastTcpConns = tcpConns;

    [self maybeRestartForFootprint:footprintMB now:now];

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

// MARK: - Soft-cap watchdog

- (void)maybeRestartForFootprint:(NSInteger)footprintMB now:(NSTimeInterval)now {
    if (footprintMB < kSoftCapFootprintMB) return;
    if (_lastReliefAttempt > 0 && (now - _lastReliefAttempt) < kReliefCooldownS) {
        return;
    }
    _lastReliefAttempt = now;

    os_log_error(gLog,
                 "soft-cap: footprint=%ldMB >= %ldMB, calling malloc_zone_pressure_relief",
                 (long)footprintMB, (long)kSoftCapFootprintMB);
    malloc_zone_pressure_relief(NULL, 0);
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
    if (!buf) {
        if (error) *error = [NSError errorWithDomain:@"MWTunnelEngine"
                                                code:4
                                            userInfo:@{NSLocalizedDescriptionKey: @"out of memory"}];
        return NO;
    }
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
