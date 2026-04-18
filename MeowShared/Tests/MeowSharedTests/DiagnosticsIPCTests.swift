import Foundation
@testable import MeowIPC
@testable import MeowModels
import Testing

@Suite("DiagnosticsIPC wire format")
struct DiagnosticsIPCTests {
    // MARK: - Canned request (tag 0x01)

    @Test
    func `canned request is exactly one byte with tag 0x01`() {
        let data = DiagnosticsIPC.encodeRequest()
        #expect(data.count == 1)
        #expect(data[0] == 0x01)
    }

    @Test
    func `isRequest only accepts exactly [0x01]`() {
        #expect(DiagnosticsIPC.isRequest(Data([0x01])))
        #expect(!DiagnosticsIPC.isRequest(Data()))
        #expect(!DiagnosticsIPC.isRequest(Data([0x02])))
        #expect(!DiagnosticsIPC.isRequest(Data([0x01, 0x02])))
    }

    @Test
    func `canned response roundtrips through JSON`() throws {
        let report = DiagnosticsReport(
            tunExists: .pass,
            dnsOk: .fail("resolve_failed"),
            tcpProxyOk: .pass,
            http204Ok: .fail("status=500"),
            memOk: .pass,
        )
        let data = try DiagnosticsIPC.encodeResponse(report)
        let decoded = try DiagnosticsIPC.decodeResponse(data)
        #expect(decoded.tunExists.pass)
        #expect(!decoded.dnsOk.pass)
        #expect(decoded.dnsOk.reason == "resolve_failed")
        #expect(decoded.http204Ok.reason == "status=500")
    }

    // MARK: - User request (tag 0x02, T4.10)

    @Test
    func `user request begins with tag 0x02 followed by JSON`() throws {
        let data = try DiagnosticsIPC.encodeUserRequest(.dns(host: "example.com", timeoutMs: 3000))
        #expect(data.count >= 2)
        #expect(data[0] == 0x02)
        // JSON body must be parseable on its own (no leading tag).
        let bodyStart = data.index(after: data.startIndex)
        let body = data.subdata(in: bodyStart ..< data.endIndex)
        #expect(!body.isEmpty)
        #expect(body.first == UInt8(ascii: "{"))
    }

    @Test
    func `user request isUserRequest disambiguates from canned`() throws {
        let cannedData = DiagnosticsIPC.encodeRequest()
        let userData = try DiagnosticsIPC.encodeUserRequest(.dns(host: "example.com", timeoutMs: 3000))
        #expect(DiagnosticsIPC.isRequest(cannedData))
        #expect(!DiagnosticsIPC.isUserRequest(cannedData))
        #expect(!DiagnosticsIPC.isRequest(userData))
        #expect(DiagnosticsIPC.isUserRequest(userData))
        #expect(!DiagnosticsIPC.isUserRequest(Data([0x02])))
        #expect(!DiagnosticsIPC.isUserRequest(Data()))
    }

    @Test
    func `user request proxyHttp roundtrips`() throws {
        let original = UserDiagnosticsRequest.proxyHttp(
            url: "https://www.gstatic.com/generate_204",
            timeoutMs: 5000,
        )
        let data = try DiagnosticsIPC.encodeUserRequest(original)
        let decoded = try DiagnosticsIPC.decodeUserRequest(data)
        guard case let .proxyHttp(url, timeoutMs) = decoded else {
            Issue.record("expected .proxyHttp, got \(decoded)")
            return
        }
        #expect(url == "https://www.gstatic.com/generate_204")
        #expect(timeoutMs == 5000)
    }

    @Test
    func `user request dns roundtrips`() throws {
        let original = UserDiagnosticsRequest.dns(host: "example.com", timeoutMs: 3000)
        let data = try DiagnosticsIPC.encodeUserRequest(original)
        let decoded = try DiagnosticsIPC.decodeUserRequest(data)
        guard case let .dns(host, timeoutMs) = decoded else {
            Issue.record("expected .dns, got \(decoded)")
            return
        }
        #expect(host == "example.com")
        #expect(timeoutMs == 3000)
    }

    @Test
    func `decodeUserRequest rejects payload without 0x02 tag`() {
        // Valid JSON but no tag byte — must surface as tagMismatch, not decode
        // silently against a shifted byte offset.
        let rawJson = Data(#"{"dns":{"host":"example.com","timeoutMs":3000}}"#.utf8)
        #expect(throws: DiagnosticsIPCError.self) {
            _ = try DiagnosticsIPC.decodeUserRequest(rawJson)
        }
    }

    // MARK: - User response

    @Test
    func `user response success roundtrips`() throws {
        let original = UserDiagnosticsResponse.success(latencyMs: 42, httpStatus: 204)
        let data = try DiagnosticsIPC.encodeUserResponse(original)
        let decoded = try DiagnosticsIPC.decodeUserResponse(data)
        #expect(decoded.success)
        #expect(decoded.latencyMs == 42)
        #expect(decoded.httpStatus == 204)
        #expect(decoded.errorReason == nil)
    }

    @Test
    func `user response failure roundtrips`() throws {
        let original = UserDiagnosticsResponse.failure(reason: "engine not running")
        let data = try DiagnosticsIPC.encodeUserResponse(original)
        let decoded = try DiagnosticsIPC.decodeUserResponse(data)
        #expect(!decoded.success)
        #expect(decoded.errorReason == "engine not running")
        #expect(decoded.latencyMs == nil)
        #expect(decoded.httpStatus == nil)
    }

    @Test
    func `user response success without httpStatus roundtrips (dns case)`() throws {
        let original = UserDiagnosticsResponse.success(latencyMs: 18)
        let data = try DiagnosticsIPC.encodeUserResponse(original)
        let decoded = try DiagnosticsIPC.decodeUserResponse(data)
        #expect(decoded.success)
        #expect(decoded.latencyMs == 18)
        #expect(decoded.httpStatus == nil)
    }
}
