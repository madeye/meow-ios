#import "MWEngineLog.h"
#import "meow_core.h"

void MWEngineLog(MWLogLevel level, NSString *msg) {
    if (msg.length == 0) return;
    meow_core_log((int)level, msg.UTF8String);
}

void MWEngineLogf(MWLogLevel level, NSString *format, ...) {
    if (format == nil) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    MWEngineLog(level, msg);
}
