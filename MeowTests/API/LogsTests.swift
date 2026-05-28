import Foundation
@testable import meow_ios
import Testing

/// Contract for `streamLogs(level:)` — the WebSocket half of `MeowAPI`
/// consumed by T4.7 Logs Screen.
///
/// `.disabled("blocked on T4.7")` — WebSocket stubbing is not built into
/// `URLProtocolStub` and lands with the T4.7 Logs Screen harness. Until
/// then these skeletons pin the `LogEntry` contract and the
/// level-picker / malformed-line behaviors the view depends on, so that
/// any drift in `App/Sources/Services/MeowAPITypes.swift` breaks the
/// build.
///
/// Fixture source: `URLProtocolStub` in `MeowTests/Support/URLProtocolStub.swift`
/// (plus a WebSocket stub helper that lands with T4.7).
@Suite("MeowAPI logs WebSocket", .tags(.api))
struct LogsTests {
    /// Compile-time anchor — drift in `LogEntry` or the `streamLogs`
    /// signature breaks this file. `streamLogs` returns synchronously; the
    /// `AsyncThrowingStream` itself is the asynchrony boundary.
    private static func _contractAnchor(api: MeowAPI) {
        _ = LogEntry.self
        _ = LogEntry.from(jsonString: "")
        let stream: AsyncThrowingStream<LogEntry, Error> = api.streamLogs(level: "info")
        _ = stream
    }

    @Test(
        .disabled("blocked on T4.7"),
    )
    func `LogEntry.from(jsonString:) decodes well-formed {type,payload}`() {
        // `LogEntry { type, payload }` — see MeowAPITypes.swift.
        // Exercise: `LogEntry.from(jsonString: #"{"type":"info","payload":"hi"}"#)`
        // must yield a non-nil entry with both fields populated.
        Issue.record("LogsTests.logEntryDecodesHappyPath not implemented — skeleton gated on T4.7")
    }

    @Test(
        .disabled("blocked on T4.7"),
    )
    func `LogEntry.from(jsonString:) returns nil on malformed JSON`() {
        // Partial frames / non-JSON keepalives must not crash the stream.
        // `LogsView.subscribe()` drops `nil` entries silently; this test
        // locks that contract in so we don't regress to an `Optional.!` or
        // `try!` anywhere in the decode path.
        Issue.record("LogsTests.logEntryMalformedYieldsNil not implemented — skeleton gated on T4.7")
    }

    @Test(
        .disabled("blocked on T4.7"),
    )
    func `streamLogs request URL embeds ?level= query param`() {
        // LogsView streams at level=debug and filters client-side.
        // The client must encode the level as `?level=<value>` on the
        // WebSocket URL — meow honors this as a server-side filter.
        Issue.record("LogsTests.streamLogsLevelQuery not implemented — skeleton gated on T4.7")
    }

    @Test(
        .disabled("blocked on T4.7"),
    )
    func `streamLogs yields entries in order; cancellation finishes the stream`() {
        // Feed three framed messages through the WebSocket stub, assert
        // the `AsyncThrowingStream` yields them in the same order with no
        // drops. Then cancel the task — `continuation.onTermination` must
        // fire and the stream must finish without a thrown error.
        Issue.record("LogsTests.streamLogsOrderingAndCancellation not implemented — skeleton gated on T4.7")
    }

    @Test(
        .disabled("blocked on T4.7"),
    )
    func `WebSocket remote close surfaces as throwing-stream error`() {
        // When the server tears down the socket (engine restart / meow
        // panic), `ws.receive()` throws. `streamLogs` auto-reconnects
        // with backoff; this test verifies the error propagation contract.
        Issue.record("LogsTests.streamLogsRemoteClosePropagates not implemented — skeleton gated on T4.7")
    }
}
