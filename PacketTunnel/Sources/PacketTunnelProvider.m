#import "PacketTunnelProvider.h"
#import "MWTunnelEngine.h"
#import "MWTunnelSettings.h"
#import "MWIPCListener.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "MWDiagnosticsRunner.h"
#import <os/log.h>
#import <mach/mach.h>
@import Network;

static const uint8_t kDiagTagCanned = 0x01;
static const uint8_t kDiagTagUser   = 0x02;
static const uint8_t kDiagTagMemory = 0x03;

static os_log_t gLog;

@implementation PacketTunnelProvider {
    MWTunnelEngine     *_engine;
    MWIPCListener      *_ipcListener;
    nw_path_monitor_t   _pathMonitor;
    dispatch_queue_t    _pathQueue;
    dispatch_source_t   _pathDebounceTimer;
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

            [self writeState:@"connected" profileID:profileID errorMessage:nil];
            completionHandler(nil);
        });
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    os_log_info(gLog, "stopTunnel reason=%ld", (long)reason);
    [self stopPathMonitor];
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

    if (completionHandler) completionHandler(nil);
}

// MARK: - IPC intent handling

- (void)handleIntent:(NSDictionary *)intent {
    NSString *command = intent[@"command"];
    if ([command isEqualToString:@"stop"]) {
        [self cancelTunnelWithError:nil];
    } else if ([command isEqualToString:@"reload"]) {
        // Full stop/start reload — M3 will add hot-reload via REST API
        os_log_info(gLog, "reload intent received (stop/start path)");
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
    MWTunnelEngine *engine = _engine;
    if (!engine) return;

    os_log_info(gLog, "path: triggering engine restart");
    self.reasserting = YES;

    __weak __typeof__(self) weak = self;
    [engine restartWithCompletion:^(BOOL success) {
        __strong __typeof__(weak) self = weak;
        if (!self) return;
        self.reasserting = NO;
        os_log_info(gLog, "path: restart finished success=%d", success);
        if (!success) {
            [self writeState:@"error" profileID:nil
                errorMessage:@"reconnect after network change failed"];
        }
    }];
}

@end
