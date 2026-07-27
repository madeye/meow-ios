#import "PacketTunnelProvider.h"
#import "MWTunnelEngine.h"
#import "MWTunnelSettings.h"
#import "MWAppGroup.h"
#import "MWPreferences.h"
#import "MWIPCListener.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "MWDiagnosticsRunner.h"
#import "MWEngineLog.h"
#import "meow_core.h"
#import <os/log.h>
#import <mach/mach.h>
#import <malloc/malloc.h>

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
    // Serializes blocking engine start/stop work. NE lifecycle callbacks can
    // arrive on different system queues; MWTunnelEngine owns non-atomic state
    // and must not be driven concurrently.
    dispatch_queue_t    _engineControlQueue;
}

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
    // The IPv6 route configuration must match the FFI's AAAA-forwarding toggle
    // (set from the same pref in MWTunnelEngine). Read it here so the TUN claims
    // a v6 address + ::/0 route only when the user enabled IPv6.
    BOOL ipv6Enabled = [[MWAppGroup defaults] boolForKey:MWPrefKeyIPv6Enabled];
    NEPacketTunnelNetworkSettings *settings =
        [MWTunnelSettings makeWithServerAddress:server ipv6Enabled:ipv6Enabled];

    __weak __typeof__(self) weak = self;
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *settingsErr) {
        if (settingsErr) {
            completionHandler(settingsErr);
            return;
        }
        dispatch_async(self->_engineControlQueue, ^{
            __strong __typeof__(weak) self = weak;
            if (!self) { completionHandler(nil); return; }

            // Duplicate-start guard: a second startTunnel on a live process must
            // not allocate a second engine generation. Without this, the second
            // generation's meow_tun_start fails ("already running") and its
            // error path calls meow_engine_stop() — tearing down the engine the
            // FIRST generation is still serving. The old tun keeps running with
            // no engine behind it: every DNS query and new TCP flow is silently
            // dropped while the VPN icon stays on.
            if (self->_engine) {
                os_log_info(gLog, "startTunnel: engine already running — duplicate start ignored");
                MWEngineLog(MWLogInfo, @"NE: duplicate startTunnel ignored — engine already running");
                [self writeState:@"connected" profileID:profileID errorMessage:nil];
                completionHandler(nil);
                return;
            }

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

            [self writeState:@"connected" profileID:profileID errorMessage:nil];
            completionHandler(nil);
        });
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    os_log_info(gLog, "stopTunnel reason=%ld", (long)reason);
    MWEngineLogf(MWLogInfo, @"NE: stopTunnel reason=%ld", (long)reason);
    dispatch_async(_engineControlQueue, ^{
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        malloc_zone_pressure_relief(NULL, 0);
        completionHandler();
    });
}

- (void)wake {
    // Probe-gated recovery, not a blind restart. Blind wake restarts were a
    // guaranteed multi-second DNS blackout and were removed in 0cee30f; but
    // their removal left the known in-process wedge class (lwIP data-path
    // freeze across background sleep/wake: process alive, VPN icon on, only
    // packets stop) with NO recovery at all in Release builds — the
    // "DNS stops working after hours in background" phenotype. The probe is
    // an end-to-end synthetic DNS query through the real packet pipeline; a
    // healthy path returns in milliseconds and nothing is restarted. Only a
    // twice-confirmed wedged path pays the restart blackout, which is strictly
    // better than staying dead until the user toggles the VPN.
    os_log_info(gLog, "wake: probing data path");
    dispatch_async(_engineControlQueue, ^{
        MWTunnelEngine *engine = self->_engine;
        if (!engine || !engine.tunStarted) {
            os_log_info(gLog, "wake: engine not running — nothing to probe");
            return;
        }
        if ([engine isDataPathHealthyWithTimeoutMs:2000]) {
            MWEngineLog(MWLogInfo, @"NE: wake — data path healthy");
            return;
        }
        // Confirm before restarting: a post-wake ingress replay burst can
        // drop probe frames (ingest is drop-on-full), so one failed probe is
        // not yet evidence of a wedge.
        if ([engine isDataPathHealthyWithTimeoutMs:2000]) {
            MWEngineLog(MWLogInfo, @"NE: wake — data path healthy on second probe");
            return;
        }
        os_log_error(gLog, "wake: data path wedged — in-place engine restart");
        MWEngineLog(MWLogError, @"NE: wake — data path wedged; in-place engine restart");
        NSError *err = nil;
        if ([engine restartWithError:&err]) {
            // New startedAt generation: the app replays persisted proxy
            // selections off this edge, same as the reload-intent restart.
            [self writeState:@"connected" profileID:nil errorMessage:nil];
            MWEngineLog(MWLogInfo, @"NE: wake-health restart complete");
        } else {
            os_log_error(gLog, "wake-health restart failed: %{public}@",
                         err.localizedDescription);
            MWEngineLogf(MWLogError, @"NE: wake-health restart failed: %@ — cancelling tunnel",
                         err.localizedDescription);
            [self writeState:@"error" profileID:nil errorMessage:err.localizedDescription];
            [self cancelTunnelWithError:nil];
        }
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
        // Config reload, hot first: reloadConfigWithError swaps
        // mode/rules/proxies in the running engine — no flow drop, no DNS
        // blackout. Fall back to an in-place restart only when the hot
        // reload fails AND the new config validates on its own: restarting
        // with a broken config would stop the healthy engine and fail to
        // bring it back up. If the restart also fails, cancel the tunnel —
        // the on-demand rule / app then recovers via full process recycle.
        os_log_info(gLog, "reload intent received");
        MWEngineLog(MWLogInfo, @"NE: reload intent received");
        dispatch_async(_engineControlQueue, ^{
            MWTunnelEngine *engine = self->_engine;
            if (!engine) {
                os_log_info(gLog, "reload ignored: engine not running");
                return;
            }
            NSError *reloadErr = nil;
            if ([engine reloadConfigWithError:&reloadErr]) {
                // Selector groups were rebuilt → the app must replay persisted
                // proxy selections. Traffic counters and startedAt (the engine
                // generation marker) are deliberately untouched.
                [MWDarwinBridge post:MWNotificationReloaded];
                os_log_info(gLog, "config hot-reload complete");
                MWEngineLog(MWLogInfo, @"NE: config hot-reload complete");
                return;
            }
            os_log_error(gLog, "hot reload failed: %{public}@",
                         reloadErr.localizedDescription);
            MWEngineLogf(MWLogError, @"NE: hot reload failed: %@",
                         reloadErr.localizedDescription);

            if (![self effectiveConfigValidates]) {
                // Broken config: keep the old one running. Log-only — the
                // engine is still healthy on the previous config, so writing
                // an "error" stage would misrepresent a connected tunnel.
                return;
            }

            NSError *restartErr = nil;
            if ([engine restartWithError:&restartErr]) {
                // New startedAt generation: traffic counters rebased to zero and
                // the app replays persisted proxy selections off this edge.
                [self writeState:@"connected" profileID:nil errorMessage:nil];
                os_log_info(gLog, "engine restart complete");
                MWEngineLog(MWLogInfo, @"NE: engine restart complete");
            } else {
                os_log_error(gLog, "engine restart failed: %{public}@ — cancelling tunnel",
                             restartErr.localizedDescription);
                MWEngineLogf(MWLogError, @"NE: engine restart failed: %@ — cancelling tunnel",
                             restartErr.localizedDescription);
                [self writeState:@"error" profileID:nil
                    errorMessage:restartErr.localizedDescription];
                [self cancelTunnelWithError:nil];
            }
        });
    }
    // "start" while running: no-op
}

// MARK: - State

- (BOOL)effectiveConfigValidates {
    NSString *yaml = [NSString stringWithContentsOfURL:[MWAppGroup effectiveConfigURL]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (!yaml) return NO;
    return meow_engine_validate_config(
               yaml.UTF8String,
               (int)[yaml lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) == 0;
}

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

@end
