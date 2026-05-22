import Foundation

/// Payload used between the app and the PacketTunnel extension's
/// `handleAppMessage` for proxy-control mutations that today round-trip
/// through `PUT http://127.0.0.1:9090/proxies/{group}`. Routing the call
/// through `sendProviderMessage` lets the extension invoke the
/// `meow_proxy_select` FFI directly against meow-rs's `SelectorGroup`
/// in-process, which:
///
///   1. eliminates the loopback HTTP hop and the URL percent-encoding /
///      Unicode-normalization step that breaks emoji-named groups (e.g.
///      `🚀 节点选择`),
///   2. removes the need to expose meow's `external-controller` on
///      `127.0.0.1:9090` solely for the picker, and
///   3. drops the apiSecret as the only thing standing between any
///      process on-device and a privileged mutation.
///
/// Tag dispatch matches the `DiagnosticsIPC` convention — the extension
/// has a single `handleAppMessage` entry point, so the first byte routes
/// the request. Streaming endpoints (logs / connections / traffic) stay
/// on HTTP because `sendProviderMessage` is single-shot request/response.
public enum ProxyControlIPC {
    /// First byte of every proxy-control request. Picked to extend
    /// `DiagnosticsIPC`'s 0x01-0x03 range without collision.
    public static let tag: UInt8 = 0x04

    public static func encodeRequest(_ request: ProxyControlRequest) throws -> Data {
        let body = try JSONEncoder().encode(request)
        var data = Data([tag])
        data.append(body)
        return data
    }

    public static func isRequest(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == tag
    }

    public static func decodeRequest(_ data: Data) throws -> ProxyControlRequest {
        guard isRequest(data) else {
            throw ProxyControlIPCError.tagMismatch
        }
        let body = data.subdata(in: 1 ..< data.count)
        return try JSONDecoder().decode(ProxyControlRequest.self, from: body)
    }

    public static func encodeResponse(_ response: ProxyControlResponse) throws -> Data {
        try JSONEncoder().encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> ProxyControlResponse {
        try JSONDecoder().decode(ProxyControlResponse.self, from: data)
    }
}

/// Request shape. Only `select` is wired today — `delay` and
/// `groupHealthcheck` will follow in a separate change once the select
/// path is proven against the emoji-group fixture.
public enum ProxyControlRequest: Codable, Sendable {
    case select(group: String, name: String)
}

/// Response shape. `success` mirrors the FFI's `0` return; on failure,
/// `errorReason` carries the sanitized message from
/// `meow_core_last_error` and `code` carries the FFI's negative return
/// code so the UI can distinguish "engine not running" from "name not in
/// selector" without string-matching.
public struct ProxyControlResponse: Codable, Sendable, Equatable {
    public var success: Bool
    public var errorReason: String?
    public var code: Int32?

    public init(success: Bool, errorReason: String? = nil, code: Int32? = nil) {
        self.success = success
        self.errorReason = errorReason
        self.code = code
    }

    public static let success = ProxyControlResponse(success: true)

    public static func failure(code: Int32, reason: String) -> ProxyControlResponse {
        ProxyControlResponse(success: false, errorReason: reason, code: code)
    }
}

public enum ProxyControlIPCError: Error, Sendable {
    case tagMismatch
}
