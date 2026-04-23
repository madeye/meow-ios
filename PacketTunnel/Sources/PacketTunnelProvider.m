#import "PacketTunnelProvider.h"
#import "MWTunnelEngine.h"
#import "MWTunnelSettings.h"
#import "MWIPCListener.h"
#import "MWSharedStore.h"
#import "MWDarwinBridge.h"
#import "MWDiagnosticsRunner.h"
#import <os/log.h>

static const uint8_t kDiagTagCanned = 0x01;
static const uint8_t kDiagTagUser   = 0x02;

static os_log_t gLog;

@implementation PacketTunnelProvider {
    MWTunnelEngine  *_engine;
    MWIPCListener   *_ipcListener;
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

            [self writeState:@"connected" profileID:profileID errorMessage:nil];
            completionHandler(nil);
        });
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    os_log_info(gLog, "stopTunnel reason=%ld", (long)reason);
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

@end
