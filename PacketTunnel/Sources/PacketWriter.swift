import Foundation
import NetworkExtension

/// Callback target for the Rust tun2socks egress path. The Rust runtime gets
/// an opaque `ctx` pointer (a retained `PacketWriter`) plus the top-level
/// `meowPacketWriteCallback`; whenever netstack produces a packet bound for
/// the utun, Rust invokes the callback, which reaches back into this class to
/// push bytes to `NEPacketTunnelFlow.writePackets`. No file descriptor, no
/// memcpy, no ObjC round-trip beyond what `writePackets` does internally.
final class PacketWriter {
    private let flow: NEPacketTunnelFlow
    let egressPackets = ManagedAtomicCounter()

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    func write(_ data: UnsafePointer<UInt8>, length: Int) {
        let packet = Data(bytes: data, count: length)
        let proto: Int32 = ((packet.first ?? 0) >> 4) == 6 ? AF_INET6 : AF_INET
        flow.writePackets([packet], withProtocols: [NSNumber(value: proto)])
        egressPackets.increment()
    }
}

/// Atomic Int64 counter via `OSAtomic`-free `_Atomic` semantics. Used from the
/// C callback (no isolation) and read from the traffic pump.
final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func increment() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func load() -> Int64 {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }
}

/// Non-capturing C function pointer bridged into `meow_tun_start`. `ctx` is
/// the opaque `Unmanaged<PacketWriter>` pointer produced in `TunnelEngine.start`.
let meowPacketWriteCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<UInt8>?,
    UInt,
) -> Void = { ctx, data, len in
    guard let ctx, let data, len > 0 else { return }
    let writer = Unmanaged<PacketWriter>.fromOpaque(ctx).takeUnretainedValue()
    writer.write(data, length: Int(len))
}
