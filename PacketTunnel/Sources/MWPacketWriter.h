#pragma once
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "mihomo_core.h"

@interface MWPacketWriter : NSObject
- (instancetype)initWithFlow:(NEPacketTunnelFlow *)flow;
- (void)writeData:(const uint8_t *)data length:(NSUInteger)length;
@property (nonatomic, readonly) int64_t egressPackets;
@end

// C callback for meow_tun_start; ctx is a CFRetained MWPacketWriter*.
void meowPacketWriterCB(void *ctx, const uint8_t *data, uintptr_t len);
