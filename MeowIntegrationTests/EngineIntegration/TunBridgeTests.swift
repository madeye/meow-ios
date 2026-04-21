import Foundation
import Testing

/// Exercises the Rust tun2socks bridge through the C ABI: start/stop
/// lifecycle, ingest return codes, and the Swift-owned egress callback.
/// The engine is brought up alongside tun2socks because (a) the SOCKS5
/// mixed listener lives inside the engine, and (b) passing `socks_port = 0`
/// to `meow_tun_start` asks the FFI to inherit the engine's mixed-port. If
/// the engine isn't running, tun_start fails with "engine not running".
/// Production (see `PacketTunnel/TunnelEngine.start`) calls the two in this
/// order for the same reason.
///
/// Packet semantics are deliberately light — we assert queueing return
/// codes and callback wiring, not payload routing. End-to-end packet
/// flow belongs in the 5-check E2E gate, which is still disabled until
/// the Home Screen lands.
///
/// `.serialized` is required because both `meow_engine_*` and
/// `meow_tun_*` are process-global singletons.
@Suite("tun2socks bridge", .tags(.tunBridge), .serialized)
struct TunBridgeTests {
    @Test
    func `tun_start attaches a Swift callback and tun_stop unwinds cleanly`() throws {
        let fixture = try EngineFixture.make()
        defer { fixture.cleanup() }
        try bootEngine(fixture)
        defer { meow_engine_stop() }

        let sink = EgressSink()
        let ctx = Unmanaged.passRetained(sink)
        defer { ctx.release() }

        let rc = meow_tun_start(ctx.toOpaque(), tunEgressCallback, 0)
        #expect(rc == 0, "tun_start failed: \(lastError())")

        meow_tun_stop()
        // Header contract: stop is idempotent.
        meow_tun_stop()
    }

    @Test
    func `tun_stop is a no-op when called before any tun_start`() {
        meow_tun_stop()
        meow_tun_stop()
    }

    @Test
    func `tun_ingest returns -1 while tun2socks is stopped`() {
        meow_tun_stop()
        let packet = minimalIPv4UDP()
        let rc = packet.withUnsafeBufferPointer { buf -> Int32 in
            meow_tun_ingest(buf.baseAddress!, UInt(buf.count))
        }
        #expect(rc == -1)
    }

    @Test
    func `tun_ingest queues a well-formed IP packet when tun2socks is running`() throws {
        let fixture = try EngineFixture.make()
        defer { fixture.cleanup() }
        try bootEngine(fixture)
        defer { meow_engine_stop() }

        let sink = EgressSink()
        let ctx = Unmanaged.passRetained(sink)
        #expect(meow_tun_start(ctx.toOpaque(), tunEgressCallback, 0) == 0,
                "tun_start failed: \(lastError())")
        defer { meow_tun_stop(); ctx.release() }

        let packet = minimalIPv4UDP()
        let rc = packet.withUnsafeBufferPointer { buf -> Int32 in
            meow_tun_ingest(buf.baseAddress!, UInt(buf.count))
        }
        #expect(rc == 0)
    }

    @Test
    func `tun_start → tun_stop → tun_start allows a clean restart cycle`() throws {
        let fixture = try EngineFixture.make()
        defer { fixture.cleanup() }
        try bootEngine(fixture)
        defer { meow_engine_stop() }

        let sink = EgressSink()
        let ctx = Unmanaged.passRetained(sink)
        defer { ctx.release() }

        #expect(meow_tun_start(ctx.toOpaque(), tunEgressCallback, 0) == 0,
                "first tun_start failed: \(lastError())")
        meow_tun_stop()

        #expect(meow_tun_start(ctx.toOpaque(), tunEgressCallback, 0) == 0,
                "second tun_start failed: \(lastError())")
        meow_tun_stop()
    }
}

extension Tag {
    @Tag static var tunBridge: Self
}

/// Callback sink retained over the lifetime of a single `tun_start` /
/// `tun_stop` pair. Mirrors `PacketTunnel/PacketWriter` in shape so the
/// ownership contract stays identical.
private final class EgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var packetCount = 0

    func record() {
        lock.lock(); packetCount &+= 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); let v = packetCount; lock.unlock(); return v
    }
}

private let tunEgressCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<UInt8>?,
    UInt,
) -> Void = { ctx, data, len in
    guard let ctx, data != nil, len > 0 else { return }
    Unmanaged<EgressSink>.fromOpaque(ctx).takeUnretainedValue().record()
}

private func bootEngine(_ fixture: EngineFixture) throws {
    meow_engine_stop()
    meow_core_init()
    fixture.homeDir.withCString { meow_core_set_home_dir($0) }
    let rc = fixture.configPath.withCString { meow_engine_start($0) }
    #expect(rc == 0, "engine_start failed: \(lastError())")
}

private func lastError() -> String {
    guard let cstr = meow_core_last_error() else { return "" }
    return String(cString: cstr)
}

/// 20-byte IPv4 + UDP skeleton addressed 10.0.0.1 → 8.8.8.8. The tun
/// bridge contract is "queued (or dropped under backpressure)" — the
/// packet doesn't have to route anywhere for `tun_ingest` to return 0.
private func minimalIPv4UDP() -> [UInt8] {
    [
        0x45, 0x00, 0x00, 0x14,
        0x00, 0x00, 0x00, 0x00,
        0x40, 0x11, 0x00, 0x00,
        0x0A, 0x00, 0x00, 0x01,
        0x08, 0x08, 0x08, 0x08,
    ]
}

/// Re-declared locally to keep the tun suite independent of
/// `EngineBootTests` — both suites touch the same process globals but
/// fixture instances are per-test to avoid cross-test dirt.
private struct EngineFixture {
    let homeDir: String
    let configPath: String

    static func make() throws -> EngineFixture {
        let base = NSTemporaryDirectory() + "meow-tun-bridge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let configPath = base + "/config.yaml"
        let yaml = """
        mixed-port: 57891
        external-controller: 127.0.0.1:59091
        mode: rule
        log-level: warning
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        """
        try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
        return EngineFixture(homeDir: base, configPath: configPath)
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: homeDir)
    }
}
