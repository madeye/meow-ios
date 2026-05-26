#import "MWPacketWriter.h"
#import <stdatomic.h>

static NSArray<NSNumber *> *sIPv4Proto;
static NSArray<NSNumber *> *sIPv6Proto;

@implementation MWPacketWriter {
    NEPacketTunnelFlow *_flow;
    _Atomic int64_t _egressPackets;
}

+ (void)initialize {
    sIPv4Proto = @[@(AF_INET)];
    sIPv6Proto = @[@(AF_INET6)];
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
        NSArray<NSNumber *> *proto = (length > 0 && (data[0] >> 4) == 6) ? sIPv6Proto : sIPv4Proto;
        [_flow writePackets:@[packet] withProtocols:proto];
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
