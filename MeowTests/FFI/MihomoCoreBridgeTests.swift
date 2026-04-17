import Foundation
import Testing

/// Thin smoke tests for the unified Rust `mihomo-ios-ffi` static library
/// exposed via `MihomoCore.xcframework`. The app target links the same
/// library as the PacketTunnel extension, but this suite only exercises
/// the pure-function / read-only subset — it never calls
/// `meow_engine_start` or `meow_tun_start`, both of which belong to the
/// extension-side coverage in `MeowIntegrationTests/EngineIntegration/`.
///
/// Purpose: catch C-ABI drift (symbol names, parameter types, return
/// conventions) before any view-layer or integration test runs. Everything
/// the engine mutates in-process — home dir, thread-local last-error, the
/// running/stopped flag — is observed, not modified in destructive ways.
///
/// `.serialized` is mandatory: `meow_core_set_home_dir` writes to a process
/// singleton and the last-error pointer is thread-local. Running these in
/// parallel would race.
@Suite("mihomo-core Swift bridge", .tags(.ffi), .serialized)
struct MihomoCoreBridgeTests {
    @Test
    func `meow_core_init is callable and idempotent`() {
        meow_core_init()
        meow_core_init()
    }

    @Test
    func `meow_core_set_home_dir accepts UTF-8`() {
        let path = NSTemporaryDirectory() + "meow-ffi-tests-非ASCII路径"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        path.withCString { meow_core_set_home_dir($0) }
    }

    @Test
    func `meow_core_set_home_dir accepts NULL`() {
        meow_core_set_home_dir(nil)
    }

    @Test
    func `meow_core_last_error pointer is always readable`() throws {
        meow_core_init()
        let ptr = meow_core_last_error()
        // Header guarantees a crate-owned, non-NULL pointer. The content is
        // thread-local — may carry a prior error set by another test on this
        // worker thread — so we don't assert emptiness, only readability.
        #expect(ptr != nil)
        _ = try String(cString: #require(ptr))
    }

    @Test
    func `meow_engine_is_running is 0 when no engine has been started`() {
        // App-side tests never call meow_engine_start. The defensive stop
        // guards against contamination from a future app-side suite that
        // might boot the engine; meow_engine_stop is documented idempotent.
        meow_engine_stop()
        #expect(meow_engine_is_running() == 0)
    }

    @Test
    func `meow_engine_validate_config surfaces YAML errors`() {
        let bad = "this: is: not: valid: ["
        let rc = bad.withCString { ptr -> Int32 in
            meow_engine_validate_config(ptr, Int32(bad.utf8.count))
        }
        #expect(rc != 0, "malformed YAML must not return success")
        let err = String(cString: meow_core_last_error())
        #expect(!err.isEmpty, "last_error must be populated after a validation failure")
    }

    @Test
    func `meow_engine_convert_subscription accepts Clash YAML`() {
        let body = """
        proxies:
          - {name: smoke, type: direct}
        """
        let bodyLen = Int32(body.utf8.count)

        // First call with out=nil to discover required capacity.
        let needed = body.withCString { ptr -> Int32 in
            meow_engine_convert_subscription(ptr, bodyLen, nil, 0)
        }
        #expect(needed >= 0, "valid Clash YAML must not return -1")

        // Second call with a buffer sized `needed + 1` for the trailing NUL.
        let cap = Int(needed) + 1
        var out = [CChar](repeating: 0, count: cap)
        let written = body.withCString { ptr -> Int32 in
            out.withUnsafeMutableBufferPointer { buf -> Int32 in
                meow_engine_convert_subscription(ptr, bodyLen, buf.baseAddress, Int32(cap))
            }
        }
        #expect(written == needed, "second call must write exactly the reported byte count")

        let yaml = String(cString: out)
        #expect(!yaml.isEmpty)
        #expect(yaml.contains("proxies"), "converted YAML must retain top-level proxies key")
    }
}

extension Tag {
    @Tag static var ffi: Self
}
