import Foundation
import MeowModels

/// Payload used between the app (DiagnosticsViewController) and the
/// PacketTunnel extension's `handleAppMessage`. The extension is the only
/// process that can answer the PRD §4.4 checks: four of them need the
/// mihomo-rust engine runtime, and `MEM_OK` needs `task_info` on the
/// extension's own mach task.
public enum DiagnosticsIPC {
    public static let messageTag: UInt8 = 0x01

    /// Encodes a "please run diagnostics" request as a single-byte tag so the
    /// extension can dispatch without instantiating a codec just for this one
    /// control plane.
    public static func encodeRequest() -> Data { Data([messageTag]) }

    public static func isRequest(_ data: Data) -> Bool {
        data.count == 1 && data[0] == messageTag
    }

    public static func encodeResponse(_ payload: DiagnosticsReport) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decodeResponse(_ data: Data) throws -> DiagnosticsReport {
        try JSONDecoder().decode(DiagnosticsReport.self, from: data)
    }
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
        memOk: DiagnosticsResultWire
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
