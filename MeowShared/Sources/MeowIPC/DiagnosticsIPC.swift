import Foundation
import MeowModels

/// Payload used between the app (DiagnosticsViewController) and the
/// PacketTunnel extension's `handleAppMessage`. The extension is the only
/// process that can answer the PRD §4.4 checks: four of them need the
/// mihomo-rust engine runtime, and `MEM_OK` needs `task_info` on the
/// extension's own mach task.
///
/// The protocol is tag-dispatched on the first byte of the request payload:
///
/// - `0x01` (exactly one byte) — "run the canned T2.6 report." Response is
///   a JSON-encoded ``DiagnosticsReport``.
/// - `0x02` (one byte tag, followed by JSON) — "run one user-initiated
///   diagnostics request." Payload body decodes to ``UserDiagnosticsRequest``
///   and the response is a JSON-encoded ``UserDiagnosticsResponse``.
/// - `0x03` (exactly one byte) — "report your current physical memory
///   footprint." Response is a JSON-encoded ``MemoryUsageResponse`` sourced
///   from `task_info(TASK_VM_INFO).phys_footprint` inside the extension —
///   the same metric iOS jetsam compares against the NE memory limit and
///   that Xcode's Memory gauge shows. This is what the Settings
///   "About / Memory" row displays; mihomo's `/memory` REST endpoint is
///   WebSocket-only in mihomo-rust and returns 400 to plain GETs, and
///   mihomo's internal accounting under-reports by the Swift/ObjC/tokio
///   overhead anyway, so the IPC path is the only reliable snapshot.
///
/// Tags share one `sendProviderMessage` channel because the extension
/// only exposes a single `handleAppMessage` entry point; the tag byte lets
/// the dispatcher route without spinning up a second IPC mailbox.
public enum DiagnosticsIPC {
    public static let messageTag: UInt8 = 0x01
    public static let userMessageTag: UInt8 = 0x02
    public static let memoryMessageTag: UInt8 = 0x03

    /// Encodes a "please run canned diagnostics" request as a single-byte tag
    /// so the extension can dispatch without instantiating a codec just for
    /// this one control plane.
    public static func encodeRequest() -> Data {
        Data([messageTag])
    }

    public static func isRequest(_ data: Data) -> Bool {
        data.count == 1 && data[0] == messageTag
    }

    public static func encodeResponse(_ payload: DiagnosticsReport) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decodeResponse(_ data: Data) throws -> DiagnosticsReport {
        try JSONDecoder().decode(DiagnosticsReport.self, from: data)
    }

    // MARK: - User-initiated diagnostics (T4.10)

    /// Encodes a user-initiated diagnostics request. Wire format is `[0x02,
    /// ...json...]` — one tag byte followed by a JSON-encoded
    /// ``UserDiagnosticsRequest``. The tag byte is cheap dispatch; JSON
    /// keeps the payload schema easy to extend with new cases later.
    public static func encodeUserRequest(_ request: UserDiagnosticsRequest) throws -> Data {
        let body = try JSONEncoder().encode(request)
        var data = Data([userMessageTag])
        data.append(body)
        return data
    }

    public static func isUserRequest(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == userMessageTag
    }

    public static func decodeUserRequest(_ data: Data) throws -> UserDiagnosticsRequest {
        guard isUserRequest(data) else {
            throw DiagnosticsIPCError.tagMismatch
        }
        let body = data.subdata(in: 1 ..< data.count)
        return try JSONDecoder().decode(UserDiagnosticsRequest.self, from: body)
    }

    public static func encodeUserResponse(_ payload: UserDiagnosticsResponse) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decodeUserResponse(_ data: Data) throws -> UserDiagnosticsResponse {
        try JSONDecoder().decode(UserDiagnosticsResponse.self, from: data)
    }

    // MARK: - Memory snapshot (tag 0x03)

    public static func encodeMemoryRequest() -> Data {
        Data([memoryMessageTag])
    }

    public static func isMemoryRequest(_ data: Data) -> Bool {
        data.count == 1 && data[0] == memoryMessageTag
    }

    public static func encodeMemoryResponse(_ payload: MemoryUsageResponse) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decodeMemoryResponse(_ data: Data) throws -> MemoryUsageResponse {
        try JSONDecoder().decode(MemoryUsageResponse.self, from: data)
    }
}

/// Current physical memory footprint of the PacketTunnel extension process,
/// in bytes. Sourced from `task_info(TASK_VM_INFO).phys_footprint` — the
/// same metric iOS jetsam compares against the NE memory limit and that
/// Xcode's Memory gauge shows (preferred over `MACH_TASK_BASIC_INFO.resident_size`,
/// which can include shared read-only pages and under-count compressed memory).
///
/// Field name kept as `residentBytes` for brevity; the actual value is the
/// physical footprint, not RSS.
public struct MemoryUsageResponse: Codable, Sendable, Equatable {
    public var residentBytes: UInt64

    public init(residentBytes: UInt64) {
        self.residentBytes = residentBytes
    }
}

public enum DiagnosticsIPCError: Error, Sendable {
    case tagMismatch
}

/// Carries one `DiagnosticsResult` per `DiagnosticsCheck`, plus the extension
/// resident-memory reading used to derive `MEM_OK`. The panel renders this
/// via `DiagnosticsLabelParser.render(...)`.
public struct DiagnosticsReport: Codable, Sendable {
    public var tunExists: DiagnosticsResultWire
    public var dnsOk: DiagnosticsResultWire
    public var tcpProxyOk: DiagnosticsResultWire
    public var http204Ok: DiagnosticsResultWire
    public var memOk: DiagnosticsResultWire

    public init(
        tunExists: DiagnosticsResultWire,
        dnsOk: DiagnosticsResultWire,
        tcpProxyOk: DiagnosticsResultWire,
        http204Ok: DiagnosticsResultWire,
        memOk: DiagnosticsResultWire,
    ) {
        self.tunExists = tunExists
        self.dnsOk = dnsOk
        self.tcpProxyOk = tcpProxyOk
        self.http204Ok = http204Ok
        self.memOk = memOk
    }

    public func asDictionary() -> [DiagnosticsCheck: DiagnosticsResult] {
        [
            .tunExists: tunExists.result,
            .dnsOk: dnsOk.result,
            .tcpProxyOk: tcpProxyOk.result,
            .http204Ok: http204Ok.result,
            .memOk: memOk.result,
        ]
    }
}

/// Codable mirror of `DiagnosticsResult` — the model type uses an associated
/// value which makes the default synthesised Codable noisy; a flat struct
/// keeps the wire format boring and easy to parse in Python (`assert-ocr.py`).
public struct DiagnosticsResultWire: Codable, Sendable {
    public var pass: Bool
    public var reason: String

    public init(pass: Bool, reason: String = "") {
        self.pass = pass
        self.reason = reason
    }

    public static let pass = DiagnosticsResultWire(pass: true)
    public static func fail(_ reason: String) -> DiagnosticsResultWire {
        DiagnosticsResultWire(pass: false, reason: reason)
    }

    public var result: DiagnosticsResult {
        pass ? .pass : .fail(reason: reason)
    }
}

/// Request shape for user-initiated diagnostics (T4.10). Direct-TCP is
/// absent because that FFI is safe to call from the host app process and
/// never needs to round-trip through IPC. The `proxyHttp` and `dns` cases
/// gate on `engine::tunnel()` inside the Rust FFI, so they must run inside
/// the PacketTunnel extension.
public enum UserDiagnosticsRequest: Codable, Sendable {
    case proxyHttp(url: String, timeoutMs: UInt32)
    case dns(host: String, timeoutMs: UInt32)
}

/// Response shape for user-initiated diagnostics (T4.10). `httpStatus` is
/// populated only for `proxyHttp` requests; `latencyMs` is populated on
/// success for both. A `success == false` response carries an
/// `errorReason` string suitable for rendering directly in the UI — the
/// Rust error is already sanitized by `DiagnosticsRunner.sanitizeReason`.
public struct UserDiagnosticsResponse: Codable, Sendable {
    public var success: Bool
    public var latencyMs: Int64?
    public var errorReason: String?
    public var httpStatus: Int32?

    public init(
        success: Bool,
        latencyMs: Int64? = nil,
        errorReason: String? = nil,
        httpStatus: Int32? = nil,
    ) {
        self.success = success
        self.latencyMs = latencyMs
        self.errorReason = errorReason
        self.httpStatus = httpStatus
    }

    public static func success(latencyMs: Int64, httpStatus: Int32? = nil) -> UserDiagnosticsResponse {
        UserDiagnosticsResponse(success: true, latencyMs: latencyMs, httpStatus: httpStatus)
    }

    public static func failure(reason: String, httpStatus: Int32? = nil) -> UserDiagnosticsResponse {
        UserDiagnosticsResponse(success: false, errorReason: reason, httpStatus: httpStatus)
    }
}
