import Foundation
import NetworkExtension

/// Bridges `NEPacketTunnelFlow` and a Unix datagram socket fd owned by the
/// Rust `tun2socks` layer. Reads raw IP packets from `packetFlow` and writes
/// each as a single datagram to `fd`; reads datagrams from `fd` back into
/// `packetFlow.writePackets`.
enum PacketPump {
    static func run(fd: Int32, packetFlow: NEPacketTunnelFlow) async {
        async let upstream: () = readFromPacketFlow(packetFlow: packetFlow, fd: fd)
        async let downstream: () = readFromFd(fd: fd, packetFlow: packetFlow)
        _ = await (upstream, downstream)
    }

    /// Packets the system wants to send go into the tunnel — forward them to
    /// the Rust fd so netstack-smoltcp can process them.
    private static func readFromPacketFlow(packetFlow: NEPacketTunnelFlow, fd: Int32) async {
        while !Task.isCancelled {
            let batch = await withCheckedContinuation { (cont: CheckedContinuation<([Data], [NSNumber]), Never>) in
                packetFlow.readPackets { packets, protocols in
                    cont.resume(returning: (packets, protocols))
                }
            }
            for packet in batch.0 {
                _ = packet.withUnsafeBytes { buf -> Int in
                    guard let base = buf.baseAddress else { return 0 }
                    return send(fd, base, buf.count, 0)
                }
            }
        }
    }

    /// Packets produced by Rust's tun2socks (i.e. reassembled TCP segments
    /// destined for the OS) are written to `packetFlow` so iOS delivers them
    /// to the appropriate socket.
    private static func readFromFd(fd: Int32, packetFlow: NEPacketTunnelFlow) async {
        let bufSize = 65_535
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while !Task.isCancelled {
            let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return recv(fd, base, bufSize, 0)
            }
            if n <= 0 { break }
            let data = Data(bytes: buffer, count: n)
            let proto = ipProtocol(for: data)
            packetFlow.writePackets([data], withProtocols: [NSNumber(value: proto)])
        }
    }

    private static func ipProtocol(for packet: Data) -> Int32 {
        guard let first = packet.first else { return AF_INET }
        return (first >> 4) == 6 ? AF_INET6 : AF_INET
    }
}
