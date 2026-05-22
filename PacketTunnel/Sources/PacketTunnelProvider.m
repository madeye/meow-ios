#import "PacketTunnelProvider.h"
#import "MWTunnelEngine.h"
#import "MWTunnelSettings.h"
#import "MWIPCListener.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "MWDiagnosticsRunner.h"
#import "meow_core.h"
#import <os/log.h>
#import <mach/mach.h>
@import Network;

// keep in sync with MeowShared/Sources/MeowIPC/DiagnosticsIPC.swift and
// MeowShared/Sources/MeowIPC/ProxyControlIPC.swift tag values
static const uint8_t kDiagTagCanned     = 0x01;
static const uint8_t kDiagTagUser       = 0x02;
static const uint8_t kDiagTagMemory     = 0x03;
static const uint8_t kProxyTagSelect    = 0x04;

// Pre-emptive process restart threshold. iOS jetsam kills NE extensions
// around 50 MB phys_footprint; we self-restart at 40 MB so the kill is
// orderly (writes a state row, logs a reason) instead of a silent jetsam.
// 10 MB headroom absorbs the burst between the check tick and exit().
static const uint64_t kMemoryRestartThresholdBytes = 40ULL * 1024ULL * 1024ULL;
static const uint64_t kMemoryWatchdogIntervalNsec  = 2ULL * NSEC_PER_SEC;

static os_log_t gLog;

@implementation PacketTunnelProvider {
    MWTunnelEngine     *_engine;
    MWIPCListener      *_ipcListener;
    nw_path_monitor_t   _pathMonitor;
    dispatch_queue_t    _pathQueue;
    dispatch_source_t   _pathDebounceTimer;
    dispatch_source_t   _memoryWatchdog;
    BOOL                _havePath;
    BOOL                _lastSatisfied;
    nw_interface_type_t _lastInterfaceType;
}

+ (void)initialize {
    if (self == [PacketTunnelProvider class]) {
        gLog = os_log_create("io.github.madeye.meow.PacketTunnel", "provider");
    }
}

// MARK: - Lifecycle

- (void)startTunnelWithOptions:(NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *))completionHandler {
    os_log_info(gLog, "startTunnel");

    NSString *server  = self.protocolConfiguration.serverAddress ?: @"192.0.2.1";
    NSString *profileID = (NSString *)options[@"profileID"];
    NEPacketTunnelNetworkSettings *settings = [MWTunnelSettings makeWithServerAddress:server];

    __weak __typeof__(self) weak = self;
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *settingsErr) {
        if (settingsErr) {
            completionHandler(settingsErr);
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __strong __typeof__(weak) self = weak;
            if (!self) { completionHandler(nil); return; }

            MWTunnelEngine *engine = [[MWTunnelEngine alloc] initWithPacketFlow:self.packetFlow];
            NSError *startErr = nil;
            if (![engine startWithError:&startErr]) {
                os_log_error(gLog, "engine start failed: %{public}@",
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
            [self startMemoryWatchdog];

            [self writeState:@"connected" profileID:profileID errorMessage:nil];
            completionHandler(nil);
        });
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    os_log_info(gLog, "stopTunnel reason=%ld", (long)reason);
    [self stopPathMonitor];
    [self stopMemoryWatchdog];
    [_engine stop];
    _engine = nil;
    [_ipcListener stop];
    _ipcListener = nil;
    [self writeState:@"stopped" profileID:nil errorMessage:nil];
    completionHandler();
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
    // Replaces `PUT http://127.0.0.1:9090/proxies/{group}` with a direct
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
    _pathQueue = dispatch_queue_create("io.github.madeye.meow.PacketTunnel.path",
                                       DISPATCH_QUEUE_SERIAL);
    _havePath = NO;
    _lastSatisfied = NO;
    _lastInterfaceType = nw_interface_type_other;

    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, _pathQueue);

    __weak __typeof__(self) weak = self;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t _Nonnull path) {
        __strong __typeof__(weak) self = weak;
        if (!self) return;
        [self handlePathUpdate:path];
    });
    nw_path_monitor_start(monitor);
    _pathMonitor = monitor;
}

- (void)stopPathMonitor {
    if (_pathDebounceTimer) {
        dispatch_source_cancel(_pathDebounceTimer);
        _pathDebounceTimer = nil;
    }
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
    _pathQueue = nil;
}

// Caller queue: _pathQueue (serial). All ivar access here is single-threaded.
- (void)handlePathUpdate:(nw_path_t)path {
    nw_path_status_t status = nw_path_get_status(path);
    BOOL satisfied = (status == nw_path_status_satisfied);

    nw_interface_type_t iface = nw_interface_type_other;
    if (satisfied) {
        if (nw_path_uses_interface_type(path, nw_interface_type_wifi)) {
            iface = nw_interface_type_wifi;
        } else if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) {
            iface = nw_interface_type_cellular;
        } else if (nw_path_uses_interface_type(path, nw_interface_type_wired)) {
            iface = nw_interface_type_wired;
        }
    }

    if (!_havePath) {
        _havePath = YES;
        _lastSatisfied = satisfied;
        _lastInterfaceType = iface;
        os_log_info(gLog, "path: initial satisfied=%d iface=%d", satisfied, iface);
        return;
    }

    BOOL meaningful = NO;
    if (satisfied && !_lastSatisfied) {
        os_log_info(gLog, "path: connectivity regained");
        meaningful = YES;
    } else if (satisfied && iface != _lastInterfaceType) {
        os_log_info(gLog, "path: interface changed %d -> %d", _lastInterfaceType, iface);
        meaningful = YES;
    }

    _lastSatisfied = satisfied;
    _lastInterfaceType = iface;

    if (meaningful) {
        [self scheduleReconnect];
    }
}

// Caller queue: _pathQueue. Coalesces a burst of path updates into one restart.
- (void)scheduleReconnect {
    if (_pathDebounceTimer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0, 0, _pathQueue);
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER,
        100 * NSEC_PER_MSEC);

    __weak __typeof__(self) weak = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong __typeof__(weak) self = weak;
        if (!self) return;
        if (self->_pathDebounceTimer) {
            dispatch_source_cancel(self->_pathDebounceTimer);
            self->_pathDebounceTimer = nil;
        }
        [self triggerReconnect];
    });
    _pathDebounceTimer = timer;
    dispatch_resume(timer);
}

- (void)triggerReconnect {
    if (!_engine) return;

    // Light-touch network-change handling: keep the VPN connected, keep
    // the TUN and engine running, and just abort every in-flight TCP
    // flow in tun2socks. Meow-tunnel's `ConnectionGuard` drops the
    // matching `Statistics.connections` entry on each task cancel, so
    // its state stays in sync with our flow registry. The next packet
    // from the app for any pre-flip flow opens a fresh dispatch and
    // dials over the new uplink. Previously we toggled `reasserting`
    // (which iOS surfaces as a "connecting" UI flicker) and restarted
    // the entire engine — heavy, and unnecessary now that we have a
    // targeted way to drop stale flows.
    //
    // UDP is intentionally not touched: it's connectionless from the
    // app's perspective, meow's NAT entries time out on their own,
    // and dropping them mid-flip would clobber in-flight DNS replies.
    int32_t aborted = meow_tun_close_all_tcp_flows();
    os_log_info(gLog, "path: closed %d TCP flows on network change", aborted);
}

// MARK: - Memory watchdog
//
// Polls TASK_VM_INFO.phys_footprint (the same byte iOS jetsam compares against
// the NE memory limit) on a background queue. When the footprint crosses
// kMemoryRestartThresholdBytes, the extension restarts itself by calling
// exit(0): NE respawns the process on the next packet / on-demand probe, and
// the cumulative memory leaks (slab fragmentation, retained per-flow state,
// rustls session caches) reset to a fresh baseline. Without this, growth
// continues past 50 MB and iOS jetsam-kills the extension — silent from the
// app's point of view, with no state row or log line.

- (void)startMemoryWatchdog {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)kMemoryWatchdogIntervalNsec),
        kMemoryWatchdogIntervalNsec,
        100 * NSEC_PER_MSEC);

    __weak __typeof__(self) weak = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong __typeof__(weak) self = weak;
        if (!self) return;
        [self checkMemoryFootprint];
    });
    _memoryWatchdog = timer;
    dispatch_resume(timer);
}

- (void)stopMemoryWatchdog {
    if (_memoryWatchdog) {
        dispatch_source_cancel(_memoryWatchdog);
        _memoryWatchdog = nil;
    }
}

- (void)checkMemoryFootprint {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(),
                                 TASK_VM_INFO,
                                 (task_info_t)&info,
                                 &count);
    if (kr != KERN_SUCCESS) return;

    uint64_t footprint = info.phys_footprint;
    if (footprint < kMemoryRestartThresholdBytes) return;

    os_log_fault(gLog,
        "memory: phys_footprint=%llu bytes >= threshold=%llu bytes — restarting process",
        footprint, kMemoryRestartThresholdBytes);

    // Persist an audit row so the app can surface "restarted due to memory"
    // on the next status read instead of presenting an unexplained
    // disconnect. Tag is intentionally distinct from user-initiated "error".
    [self writeState:@"error"
           profileID:nil
        errorMessage:[NSString stringWithFormat:
                      @"restarted: memory %llu MB exceeded %llu MB cap",
                      footprint / (1024ULL * 1024ULL),
                      kMemoryRestartThresholdBytes / (1024ULL * 1024ULL)]];

    // exit(0) is the only way to truly drop accumulated allocations. NE
    // respawns the extension on the next demand (on-demand probe, app
    // re-toggle). cancelTunnelWithError: would tear down the session but
    // keep this same dirtied process alive for the next start cycle.
    exit(0);
}

@end
