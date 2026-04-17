import Foundation
import Testing

/// Exercises the mihomo-rust engine lifecycle through the C ABI — boot,
/// idempotent start/stop, config validation, and traffic counters. These
/// call the real `MihomoCore.xcframework` rather than mocking, so they
/// verify that Dev's `TunnelEngine.start()` pipeline (write effective
/// config → init → start → is_running) actually works against the linked
/// library.
///
/// Scope is deliberately narrow: we don't exercise tun2socks here (that's
/// #12) or the REST controller (that's separate traffic/diagnostics
/// coverage). The only process-global state touched is the engine
/// lifecycle and the thread-local last-error pointer.
///
/// `.serialized` is required — the engine is a process singleton, so
/// parallel start/stop would race.
@Suite("mihomo-rust engine lifecycle", .tags(.engine), .serialized)
struct EngineBootTests {
    @Test
    func `engine start toggles is_running and stop unwinds it`() throws {
        let fixture = try EngineFixture.make()
        defer { fixture.cleanup() }

        meow_core_init()
        fixture.homeDir.withCString { meow_core_set_home_dir($0) }

        meow_engine_stop()
        #expect(meow_engine_is_running() == 0, "stale engine from prior test")

        let rc = fixture.configPath.withCString { meow_engine_start($0) }
        #expect(rc == 0, "engine start failed: \(String(cString: meow_core_last_error()))")
        #expect(meow_engine_is_running() == 1)

        meow_engine_stop()
        #expect(meow_engine_is_running() == 0)
    }

    @Test
    func `second engine_start is a no-op, not an error`() throws {
        let fixture = try EngineFixture.make()
        defer { fixture.cleanup(); meow_engine_stop() }

        meow_core_init()
        fixture.homeDir.withCString { meow_core_set_home_dir($0) }

        let rc1 = fixture.configPath.withCString { meow_engine_start($0) }
        #expect(rc1 == 0, "first start failed: \(String(cString: meow_core_last_error()))")

        let rc2 = fixture.configPath.withCString { meow_engine_start($0) }
        #expect(rc2 == 0, "second start should be idempotent, got: \(String(cString: meow_core_last_error()))")
        #expect(meow_engine_is_running() == 1)

        meow_engine_stop()
    }

    @Test
    func `engine_stop is idempotent before or after start`() {
        meow_engine_stop()
        meow_engine_stop()
        #expect(meow_engine_is_running() == 0)
    }

    @Test
    func `engine_start → engine_stop → engine_start releases the REST port`() throws {
        let fixture = try EngineFixture.make()
        defer { fixture.cleanup(); meow_engine_stop() }

        meow_core_init()
        fixture.homeDir.withCString { meow_core_set_home_dir($0) }
        meow_engine_stop()

        let rc1 = fixture.configPath.withCString { meow_engine_start($0) }
        #expect(rc1 == 0, "first start failed: \(String(cString: meow_core_last_error()))")

        meow_engine_stop()
        #expect(meow_engine_is_running() == 0)

        let rc2 = fixture.configPath.withCString { meow_engine_start($0) }
        let err2 = String(cString: meow_core_last_error())
        #expect(rc2 == 0, "second start failed (likely EADDRINUSE on external-controller): \(err2)")
        #expect(meow_engine_is_running() == 1)
    }

    @Test
    func `engine_start returns -1 when the config path does not exist`() {
        meow_engine_stop()
        let bogus = "/nonexistent/path/\(UUID().uuidString).yaml"
        let rc = bogus.withCString { meow_engine_start($0) }
        #expect(rc != 0)
        let err = String(cString: meow_core_last_error())
        #expect(!err.isEmpty, "last_error must be populated on start failure")
        #expect(meow_engine_is_running() == 0)
    }

    @Test
    func `engine_traffic returns zero counters before any start`() {
        meow_engine_stop()
        var up: Int64 = -1
        var down: Int64 = -1
        meow_engine_traffic(&up, &down)
        #expect(up == 0)
        #expect(down == 0)
    }

    @Test
    func `engine_traffic accepts NULL output pointers`() {
        meow_engine_traffic(nil, nil)
    }
}

extension Tag {
    @Tag static var engine: Self
}

/// Scratch directory + minimal valid Clash YAML for boot tests. Uses
/// non-default ports to avoid colliding with a real mihomo instance on
/// the same host; `mixed-port` and `external-controller` are both
/// picked well outside the 7890/9090 defaults the extension uses in
/// production.
private struct EngineFixture {
    let homeDir: String
    let configPath: String

    static func make() throws -> EngineFixture {
        let base = NSTemporaryDirectory() + "meow-engine-boot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let configPath = base + "/config.yaml"
        let yaml = """
        mixed-port: 57890
        external-controller: 127.0.0.1:59090
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
