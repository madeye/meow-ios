#import "MWPacketWriter.h"
#import <stdatomic.h>

@implementation MWPacketWriter {
    NEPacketTunnelFlow *_flow;
    _Atomic int64_t _egressPackets;
}

- (instancetype)initWithFlow:(NEPacketTunnelFlow *)flow {
    self = [super init];
    if (self) {
        _flow = flow;
        atomic_init(&_egressPackets, 0);
    }
    return self;
}

- (void)writeData:(const uint8_t *)data length:(NSUInteger)length {
    @autoreleasepool {
        NSData *packet = [NSData dataWithBytes:data length:length];
        int32_t proto = ((length > 0 && (data[0] >> 4) == 6)) ? AF_INET6 : AF_INET;
        [_flow writePackets:@[packet] withProtocols:@[@(proto)]];
        atomic_fetch_add_explicit(&_egressPackets, 1, memory_order_relaxed);
    }
}

- (int64_t)egressPackets {
    return atomic_load_explicit(&_egressPackets, memory_order_relaxed);
}

@end

void meowPacketWriterCB(void *ctx, const uint8_t *data, uintptr_t len) {
    if (!ctx || !data || len == 0) return;
    MWPacketWriter *writer = (__bridge MWPacketWriter *)ctx;
    [writer writeData:data length:(NSUInteger)len];
}
