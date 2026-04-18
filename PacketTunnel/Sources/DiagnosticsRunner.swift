import Darwin
import Foundation
import MeowIPC
import MeowModels

/// Executes the PRD §4.4 Diagnostics Surface checks inside the PacketTunnel
/// extension. The app can't run these directly — four of five require the
/// engine's tokio runtime (live in the extension), and `MEM_OK` needs
/// `task_info` on the extension's own mach task.
enum DiagnosticsRunner {
    /// Threshold from PRD §4.4 / TEST_STRATEGY §8.1. PASS iff resident ≤ 14 MB;
    /// any sample ≥ 15 MB is a ship-blocker. The "kill zone" between 14 and
    /// 15 MB is intentionally FAIL so we don't ship right at the cliff.
    static let memoryPassLimitMB: Int = 14
    static let memoryFailLimitMB: Int = 15

    static func run(engineRunning: Bool, tunStarted: Bool) -> DiagnosticsReport {
        DiagnosticsReport(
            tunExists: tunExists(engineRunning: engineRunning, tunStarted: tunStarted),
            dnsOk: dnsOk(),
            tcpProxyOk: tcpProxyOk(),
            http204Ok: http204Ok(),
            memOk: memOk(),
        )
    }

    // MARK: - Individual checks

    private static func tunExists(engineRunning: Bool, tunStarted: Bool) -> DiagnosticsResultWire {
        if !engineRunning { return .fail("engine_not_running") }
        if !tunStarted { return .fail("tun_not_started") }
        return .pass
    }

    private static func dnsOk() -> DiagnosticsResultWire {
        var buf = [CChar](repeating: 0, count: 512)
        let rc = buf.withUnsafeMutableBufferPointer { buf -> Int32 in
            "example.com".withCString { host in
                meow_engine_test_dns(host, 2000, buf.baseAddress, Int32(buf.count))
            }
        }
        if rc < 0 { return .fail(lastRustError(fallback: "resolve_failed")) }
        let answer = String(cString: buf)
        if answer.isEmpty { return .fail("empty_answer") }
        return .pass
    }

    private static func tcpProxyOk() -> DiagnosticsResultWire {
        var ms: Int64 = 0
        let rc = "1.1.1.1".withCString { host in
            meow_engine_test_direct_tcp(host, 443, 3000, &ms)
        }
        if rc < 0 { return .fail(lastRustError(fallback: "connect_failed")) }
        return .pass
    }

    private static func http204Ok() -> DiagnosticsResultWire {
        var status: Int32 = 0
        var ms: Int64 = 0
        let rc = "http://www.gstatic.com/generate_204".withCString { url in
            meow_engine_test_proxy_http(url, 5000, &status, &ms)
        }
        if rc < 0 { return .fail(lastRustError(fallback: "request_failed")) }
        if status != 204 { return .fail("status=\(status)") }
        return .pass
    }

    private static func memOk() -> DiagnosticsResultWire {
        let mb = residentMemoryMB()
        if mb < 0 { return .fail("task_info_failed") }
        if mb <= memoryPassLimitMB { return .pass }
        return .fail("mem=\(mb)mb>=\(memoryFailLimitMB)mb")
    }

    // MARK: - User-initiated diagnostics (T4.10)

    /// Dispatcher for user-initiated diagnostics. Only `proxyHttp` and `dns`
    /// route through here — `directTcp` runs in-process on the app side and
    /// never reaches the extension.
    static func runUser(request: UserDiagnosticsRequest) -> UserDiagnosticsResponse {
        switch request {
        case let .proxyHttp(url, timeoutMs):
            userProxyHttp(url: url, timeoutMs: timeoutMs)
        case let .dns(host, timeoutMs):
            userDns(host: host, timeoutMs: timeoutMs)
        }
    }

    static func userProxyHttp(url: String, timeoutMs: UInt32) -> UserDiagnosticsResponse {
        var status: Int32 = 0
        var ms: Int64 = 0
        let rc = url.withCString { ptr in
            meow_engine_test_proxy_http(ptr, Int32(clamping: timeoutMs), &status, &ms)
        }
        if rc < 0 {
            return .failure(reason: lastRustError(fallback: "request_failed"))
        }
        return .success(latencyMs: ms, httpStatus: status)
    }

    static func userDns(host: String, timeoutMs: UInt32) -> UserDiagnosticsResponse {
        var buf = [CChar](repeating: 0, count: 512)
        var ms: Int64 = 0
        let before = Date()
        let rc = buf.withUnsafeMutableBufferPointer { buf -> Int32 in
            host.withCString { ptr in
                meow_engine_test_dns(ptr, Int32(clamping: timeoutMs), buf.baseAddress, Int32(buf.count))
            }
        }
        ms = Int64(Date().timeIntervalSince(before) * 1000)
        if rc < 0 {
            return .failure(reason: lastRustError(fallback: "resolve_failed"))
        }
        let answer = String(cString: buf)
        if answer.isEmpty {
            return .failure(reason: "empty_answer")
        }
        return .success(latencyMs: ms)
    }

    // MARK: - Helpers

    /// Returns resident memory in MB for the current mach task, or -1 on
    /// failure. Uses `MACH_TASK_BASIC_INFO` because it reports
    /// `resident_size` — which is the number NE's 15 MB hard-cap is measured
    /// against (per Apple Tech Note TN3134).
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if rc != KERN_SUCCESS { return -1 }
        return Int(info.resident_size) / (1024 * 1024)
    }

    private static func lastRustError(fallback: String) -> String {
        if let cstr = meow_core_last_error() {
            let msg = String(cString: cstr)
            if !msg.isEmpty { return sanitizeReason(msg) }
        }
        return fallback
    }

    /// PRD §4.4 label grammar is `FAIL(<reason>)`, separator is ASCII — strip
    /// newlines and parens so a rich Rust error doesn't break the parser.
    private static func sanitizeReason(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw.unicodeScalars {
            if ch == "\n" || ch == "\r" { out.append(" "); continue }
            if ch == "(" || ch == ")" { continue }
            out.unicodeScalars.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
