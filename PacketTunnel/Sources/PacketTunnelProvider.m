#import "PacketTunnelProvider.h"
#import "MWTunnelEngine.h"
#import "MWTunnelSettings.h"
#import "MWIPCListener.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "MWDiagnosticsRunner.h"
#import "MWEngineLog.h"
#import "meow_core.h"
#import <os/log.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <stdatomic.h>
@import Network;

// keep in sync with MeowShared/Sources/MeowIPC/DiagnosticsIPC.swift and
// MeowShared/Sources/MeowIPC/ProxyControlIPC.swift tag values
static const uint8_t kDiagTagCanned     = 0x01;
static const uint8_t kDiagTagUser       = 0x02;
static const uint8_t kDiagTagMemory     = 0x03;
static const uint8_t kProxyTagSelect    = 0x04;

static os_log_t gLog;

@implementation PacketTunnelProvider {
    MWTunnelEngine     *_engine;
    MWIPCListener      *_ipcListener;
    nw_path_monitor_t   _pathMonitor;
    dispatch_queue_t    _pathQueue;
    BOOL                _havePath;
    BOOL                _lastSatisfied;
    nw_interface_type_t _lastInterfaceType;
    BOOL                _lastHasIPv4;
    BOOL                _lastHasIPv6;
    // Serializes blocking engine start/stop/restart work. NE lifecycle
    // callbacks can arrive on different system queues; MWTunnelEngine owns
    // non-atomic state and must not be driven concurrently.
    dispatch_queue_t    _engineControlQueue;
    // Monotonic counter bumped by every restart source/invalidator. A debounced
    // restart block captures the value at schedule time and only runs if it's
    // still current when the debounce window elapses, so a burst of path
    // changes collapses to a single restart after things settle.
    _Atomic uint64_t    _restartGeneration;
    // Bumped whenever a path monitor starts or stops. Path callbacks capture it
    // so a canceled monitor cannot schedule a delayed restart for a later
    // tunnel generation.
    _Atomic uint64_t    _pathGeneration;
}

// Quiet window after the last path event before a triggered engine restart
// actually fires. Long enough to ride out rapid path churn without stacking
// restarts, short enough that a genuine path change recovers connectivity
// quickly.
static const NSTimeInterval kEngineRestartDebounceS = 3.0;

+ (void)initialize {
    if (self == [PacketTunnelProvider class]) {
        gLog = os_log_create("com.tangzixiang.meow.PacketTunnel", "provider");
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                    QOS_CLASS_USER_INITIATED,
                                                    0);
        _engineControlQueue = dispatch_queue_create(
            "com.tangzixiang.meow.PacketTunnel.engine-control", attr);
        atomic_init(&_restartGeneration, 0);
        atomic_init(&_pathGeneration, 0);
    }
    return self;
}

// MARK: - Lifecycle

- (void)startTunnelWithOptions:(NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *))completionHandler {
    os_log_info(gLog, "startTunnel");
    MWEngineLog(MWLogInfo, @"NE: startTunnel");

    NSString *server  = self.protocolConfiguration.serverAddress ?: @"192.0.2.1";
    NSString *profileID = (NSString *)options[@"profileID"];
    NEPacketTunnelNetworkSettings *settings = [MWTunnelSettings makeWithServerAddress:server];

    __weak __typeof__(self) weak = self;
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *settingsErr) {
        if (settingsErr) {
            completionHandler(settingsErr);
            return;
        }
        dispatch_async(self->_engineControlQueue, ^{
            __strong __typeof__(weak) self = weak;
            if (!self) { completionHandler(nil); return; }

            MWTunnelEngine *engine = [[MWTunnelEngine alloc] initWithPacketFlow:self.packetFlow];
            NSError *startErr = nil;
            if (![engine startWithError:&startErr]) {
                os_log_error(gLog, "engine start failed: %{public}@",
                             startErr.localizedDescription);
                MWEngineLogf(MWLogError, @"NE: engine start failed: %@",
                             startErr.localizedDescription);
                [self writeState:@"error" profileID:nil
                    errorMessage:startErr.localizedDescription];
                completionHandler(startErr);
                return;
            }
            self->_engine = engine;

            MWIPCListener *listener = [[MWIPCListener alloc]
                initWithHandler:^(NSDictionary *intent) {
                    [self handleIntent:intent];
                }];
            [listener start];
            self->_ipcListener = listener;

            [self startPathMonitor];

            [self writeState:@"connected" profileID:profileID errorMessage:nil];
            completionHandler(nil);
        });
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    os_log_info(gLog, "stopTunnel reason=%ld", (long)reason);
    MWEngineLogf(MWLogInfo, @"NE: stopTunnel reason=%ld", (long)reason);
    atomic_fetch_add_explicit(&_restartGeneration, 1, memory_order_relaxed);
    dispatch_async(_engineControlQueue, ^{
        [self stopPathMonitor];
        MWTunnelEngine *engine = self->_engine;
        self->_engine = nil;
        [engine stop];
        MWIPCListener *listener = self->_ipcListener;
        self->_ipcListener = nil;
        [listener stop];
        [self writeState:@"stopped" profileID:nil errorMessage:nil];
        completionHandler();
    });
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler {
    os_log_info(gLog, "sleep: keeping tun active before device sleep");
    MWEngineLog(MWLogInfo, @"NE: sleep — keeping tun active before device sleep");
    // Invalidate any pending engine restart: we're heading back to sleep, so a
    // restart now would just be torn down. Bumping the generation makes the
    // scheduled block bail when it fires.
    atomic_fetch_add_explicit(&_restartGeneration, 1, memory_order_relaxed);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        malloc_zone_pressure_relief(NULL, 0);
        completionHandler();
    });
}

- (void)wake {
    os_log_info(gLog, "wake: tun remained active");
    MWEngineLog(MWLogInfo, @"NE: wake — tun remained active");
}

- (void)scheduleEngineRestartForReason:(NSString *)reason {
    uint64_t gen = atomic_fetch_add_explicit(&_restartGeneration, 1, memory_order_relaxed) + 1;
    __weak __typeof__(self) weak = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEngineRestartDebounceS * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __strong __typeof__(weak) self = weak;
            if (!self) return;
            if (atomic_load_explicit(&self->_restartGeneration, memory_order_relaxed) != gen) {
                os_log_info(gLog, "%{public}@ restart: superseded by newer event, skipping",
                            reason);
                return;
            }
            [self restartEngineForGeneration:gen reason:reason];
        });
}

// Restart the running engine in place. No-op if no engine is running (e.g.
// restart raced a stop). Runs on _engineControlQueue so it cannot interleave with
// a user/app stop.
- (void)restartEngineForGeneration:(uint64_t)gen reason:(NSString *)reason {
    dispatch_async(_engineControlQueue, ^{
        if (atomic_load_explicit(&self->_restartGeneration, memory_order_relaxed) != gen) {
            os_log_info(gLog, "%{public}@ restart: superseded before engine restart, skipping",
                        reason);
            return;
        }

        MWTunnelEngine *engine = self->_engine;
        if (!engine) {
            os_log_info(gLog, "%{public}@ restart: no engine running, skipping", reason);
            return;
        }

        NSError *startErr = nil;
        if (![engine restartWithError:&startErr]) {
            os_log_error(gLog, "%{public}@ restart: engine start failed: %{public}@",
                         reason,
                         startErr.localizedDescription);
            MWEngineLogf(MWLogError, @"NE: %@ restart — engine start failed: %@",
                         reason, startErr.localizedDescription);
            self->_engine = nil;
            [self writeState:@"error" profileID:nil errorMessage:startErr.localizedDescription];
            // A failed restart leaves no working data path. Tear the tunnel down so
            // NE on-demand / the app can re-establish it cleanly rather than
            // sitting connected-but-dead.
            [self cancelTunnelWithError:startErr];
            return;
        }

        os_log_info(gLog, "%{public}@ restart: engine restarted", reason);
        MWEngineLogf(MWLogInfo, @"NE: %@ restart — engine restarted", reason);
    });
}

// MARK: - App messages

- (void)handleAppMessage:(NSData *)messageData
       completionHandler:(void (^)(NSData *))completionHandler {

    // Canned diagnostics (0x01)
    if (messageData.length == 1 &&
        ((const uint8_t *)messageData.bytes)[0] == kDiagTagCanned) {
        MWTunnelEngine *engine = _engine;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *report;
            if (engine) {
                report = [engine runDiagnostics];
            } else {
                NSDictionary *notRunning = @{@"pass": @NO, @"reason": @"engine_not_running"};
                report = @{
                    @"tunExists":  notRunning, @"dnsOk":      notRunning,
                    @"tcpProxyOk": notRunning, @"http204Ok":  notRunning,
                    @"memOk":      notRunning,
                };
            }
            NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil]
                           ?: [NSData data];
            if (completionHandler) completionHandler(data);
        });
        return;
    }

    // Memory snapshot (0x03): TASK_VM_INFO.phys_footprint — the same
    // "memory footprint" metric iOS jetsam compares against the NE limit
    // and that Xcode's Memory gauge displays. Preferred over
    // MACH_TASK_BASIC_INFO.resident_size because resident_size can include
    // read-only shared pages and under-count compressed memory.
    if (messageData.length == 1 &&
        ((const uint8_t *)messageData.bytes)[0] == kDiagTagMemory) {
        task_vm_info_data_t info;
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        kern_return_t kr = task_info(mach_task_self(),
                                     TASK_VM_INFO,
                                     (task_info_t)&info,
                                     &count);
        uint64_t footprint = (kr == KERN_SUCCESS) ? info.phys_footprint : 0;
        NSDictionary *response = @{@"residentBytes": @(footprint)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil]
                       ?: [NSData data];
        if (completionHandler) completionHandler(data);
        return;
    }

    // User-initiated diagnostics (0x02 + JSON)
    if (messageData.length >= 2 &&
        ((const uint8_t *)messageData.bytes)[0] == kDiagTagUser) {
        NSData *body = [messageData subdataWithRange:NSMakeRange(1, messageData.length - 1)];
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (!request) { if (completionHandler) completionHandler(nil); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *response = [MWDiagnosticsRunner runUserRequest:request];
            NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil]
                           ?: [NSData data];
            if (completionHandler) completionHandler(data);
        });
        return;
    }

    // Proxy control (0x04 + JSON):
    //
    //   { "select": { "group": "🚀 …", "name": "🇭🇰 01" } }
    //
    // Replaces `PUT /proxies/{group}` on the loopback REST API with a direct
    // call into the in-process selector — no loopback hop, no URL
    // percent-encoding step that breaks emoji / CJK / space-bearing
    // group names.
    if (messageData.length >= 2 &&
        ((const uint8_t *)messageData.bytes)[0] == kProxyTagSelect) {
        NSData *body = [messageData subdataWithRange:NSMakeRange(1, messageData.length - 1)];
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![request isKindOfClass:[NSDictionary class]]) {
            if (completionHandler) completionHandler(nil);
            return;
        }
        NSDictionary *select = request[@"select"];
        if (![select isKindOfClass:[NSDictionary class]]) {
            if (completionHandler) completionHandler(nil);
            return;
        }
        NSString *group = select[@"group"];
        NSString *name  = select[@"name"];
        if (![group isKindOfClass:[NSString class]] ||
            ![name  isKindOfClass:[NSString class]]) {
            if (completionHandler) completionHandler(nil);
            return;
        }
        if (!group || !name) {
            if (completionHandler) completionHandler(nil);
            return;
        }
        // The FFI is non-blocking (a parking_lot RwLock write inside
        // SelectorGroup) but we still hop off the main queue so the
        // tag-dispatch path stays uniform with the diagnostics handlers.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int32_t code = (int32_t)meow_proxy_select(
                [group UTF8String], [name UTF8String]);
            NSMutableDictionary *response = [NSMutableDictionary dictionary];
            // `@(code == 0)` boxes the comparison result as a plain
            // NSNumber (int 0/1), which NSJSONSerialization emits as `1`
            // — and Swift's auto-Codable Bool decoder rejects integers,
            // so the IPC response fails to decode app-side. `@YES`/`@NO`
            // box as __NSCFBoolean, which serializes as `true`/`false`.
            response[@"success"] = (code == 0) ? @YES : @NO;
            response[@"code"]    = @(code);
            if (code != 0) {
                const char *err = meow_core_last_error();
                if (err && *err) {
                    response[@"errorReason"] = [NSString stringWithUTF8String:err];
                }
                os_log_error(gLog, "proxy_select(%{public}@, %{public}@) → %d",
                             group, name, code);
            } else {
                os_log_info(gLog, "proxy_select(%{public}@, %{public}@) → ok",
                            group, name);
            }
            NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil]
                           ?: [NSData data];
            if (completionHandler) completionHandler(data);
        });
        return;
    }

    if (completionHandler) completionHandler(nil);
}

// MARK: - IPC intent handling

- (void)handleIntent:(NSDictionary *)intent {
    NSString *command = intent[@"command"];
    if ([command isEqualToString:@"stop"]) {
        [self cancelTunnelWithError:nil];
    } else if ([command isEqualToString:@"reload"]) {
        // `reload` is currently a stop-only shim: the extension cancels the
        // tunnel and the app is expected to re-trigger `start` once it
        // observes the disconnected stage. M3 will add hot-reload via the
        // meow REST API and avoid the round-trip.
        os_log_info(gLog, "reload intent received (stop-only shim; app must restart)");
        [self cancelTunnelWithError:nil];
    }
    // "start" while running: no-op
}

// MARK: - State

- (void)writeState:(NSString *)stage
         profileID:(nullable NSString *)profileID
      errorMessage:(nullable NSString *)errorMessage {
    NSMutableDictionary *state = [([MWSharedStore readState] ?: @{}) mutableCopy];
    state[@"stage"] = stage;
    if (profileID)    state[@"profileID"]    = profileID;
    if (errorMessage) state[@"errorMessage"] = errorMessage;
    else              [state removeObjectForKey:@"errorMessage"];
    if ([stage isEqualToString:@"connected"]) {
        state[@"startedAt"] = @([[NSDate date] timeIntervalSince1970]);
    }
    NSError *err = nil;
    if (![MWSharedStore writeState:state error:&err]) {
        os_log_error(gLog, "state write failed: %{public}@", err);
        return;
    }
    [MWDarwinBridge post:MWNotificationState];
}

// MARK: - Network path monitoring

- (void)startPathMonitor {
    uint64_t pathGen = atomic_fetch_add_explicit(&_pathGeneration, 1, memory_order_relaxed) + 1;
    _pathQueue = dispatch_queue_create("com.tangzixiang.meow.PacketTunnel.path",
                                       DISPATCH_QUEUE_SERIAL);
    _havePath = NO;
    _lastSatisfied = NO;
    _lastInterfaceType = nw_interface_type_other;
    _lastHasIPv4 = NO;
    _lastHasIPv6 = NO;

    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, _pathQueue);

    __weak __typeof__(self) weak = self;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t _Nonnull path) {
        __strong __typeof__(weak) self = weak;
        if (!self) return;
        [self handlePathUpdate:path generation:pathGen];
    });
    nw_path_monitor_start(monitor);
    _pathMonitor = monitor;
}

- (void)stopPathMonitor {
    atomic_fetch_add_explicit(&_pathGeneration, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&_restartGeneration, 1, memory_order_relaxed);
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
    _pathQueue = nil;
}

// Caller queue: _pathQueue (serial). All ivar access here is single-threaded.
- (void)handlePathUpdate:(nw_path_t)path generation:(uint64_t)pathGen {
    if (atomic_load_explicit(&_pathGeneration, memory_order_relaxed) != pathGen) {
        os_log_info(gLog, "path: stale monitor update ignored");
        return;
    }

    nw_path_status_t status = nw_path_get_status(path);
    BOOL satisfied = (status == nw_path_status_satisfied);

    nw_interface_type_t iface = nw_interface_type_other;
    BOOL hasIPv4 = NO;
    BOOL hasIPv6 = NO;
    if (satisfied) {
        if (nw_path_uses_interface_type(path, nw_interface_type_wifi)) {
            iface = nw_interface_type_wifi;
        } else if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) {
            iface = nw_interface_type_cellular;
        } else if (nw_path_uses_interface_type(path, nw_interface_type_wired)) {
            iface = nw_interface_type_wired;
        }
        hasIPv4 = nw_path_has_ipv4(path);
        hasIPv6 = nw_path_has_ipv6(path);
    }

    if (!_havePath) {
        _havePath = YES;
        _lastSatisfied = satisfied;
        _lastInterfaceType = iface;
        _lastHasIPv4 = hasIPv4;
        _lastHasIPv6 = hasIPv6;
        os_log_info(gLog, "path: initial satisfied=%d iface=%d v4=%d v6=%d",
                    satisfied, iface, hasIPv4, hasIPv6);
        return;
    }

    BOOL shouldRestart = NO;
    if (satisfied && !_lastSatisfied) {
        os_log_info(gLog, "path: connectivity regained");
        MWEngineLog(MWLogInfo, @"NE: path — connectivity regained");
        shouldRestart = YES;
    } else if (satisfied && iface != _lastInterfaceType) {
        os_log_info(gLog, "path: interface changed %d -> %d", _lastInterfaceType, iface);
        MWEngineLogf(MWLogInfo, @"NE: path — interface changed %d -> %d",
                     _lastInterfaceType, iface);
        shouldRestart = YES;
    } else if (satisfied && (hasIPv4 != _lastHasIPv4 || hasIPv6 != _lastHasIPv6)) {
        // Same interface, same satisfied state, but the address-family set
        // changed — e.g. the Wi-Fi network silently lost (or gained) IPv6
        // via expired RAs or an upstream change. Restart the engine + tun2socks
        // after a debounce so the fresh stack tracks the new network shape.
        os_log_info(gLog, "path: address family changed v4 %d -> %d, v6 %d -> %d",
                    _lastHasIPv4, hasIPv4, _lastHasIPv6, hasIPv6);
        MWEngineLogf(MWLogInfo, @"NE: path — address family changed v4 %d -> %d, v6 %d -> %d",
                     _lastHasIPv4, hasIPv4, _lastHasIPv6, hasIPv6);
        shouldRestart = YES;
    }

    _lastSatisfied = satisfied;
    _lastInterfaceType = iface;
    _lastHasIPv4 = hasIPv4;
    _lastHasIPv6 = hasIPv6;

    if (shouldRestart) {
        os_log_info(gLog, "path: scheduling debounced engine restart");
        MWEngineLog(MWLogInfo, @"NE: path — scheduling debounced engine restart");
        [self scheduleEngineRestartForReason:@"path"];
    }
}

@end
