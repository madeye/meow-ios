import Foundation
@testable import meow_ios
import Testing

/// Contract for the Connections half of the mihomo REST client (T3.4) — the
/// slice consumed by T4.5 Connections Screen.
///
/// The `.disabled("blocked on T4.5")` attribute is deliberate: the REST
/// methods already exist on `MihomoAPI`, but the full URLProtocolStub
/// harness for the `@Observable` client (shared with `MihomoAPITests.swift`)
/// lands with T4.5 when the Connections Screen goes through end-to-end
/// wiring. Until then these tests exist to:
///
///   1. Compile against today's `Connection` / `ConnectionsResponse`
///      contract from `App/Sources/Services/MihomoAPITypes.swift` — if any
///      field gets renamed or retyped, this file fails to build (the point
///      of skeleton tests, per team-lead).
///   2. Pin the endpoint list T4.5 must satisfy: polling `/connections`,
///      `DELETE /connections/{id}`, `DELETE /connections`, plus empty-list
///      and HTTP-error handling.
///
/// Fixture source: `URLProtocolStub` in `MeowTests/Support/URLProtocolStub.swift`.
@Suite("MihomoAPI connections endpoints", .tags(.api))
struct ConnectionsTests {
    /// Compile-time anchor: if any of the shapes below drifts, this file
    /// fails to build. That is the point of skeleton tests.
    private static func _contractAnchor(api: MihomoAPI) async throws {
        _ = ConnectionsResponse.self
        _ = Connection.self
        _ = Connection.Metadata.self
        _ = MihomoAPIError.http(status: 0)
        _ = try await api.getConnections()
        try await api.closeConnection(id: "")
        try await api.closeAllConnections()
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `GET /connections decodes ConnectionsResponse with non-empty list`() {
        // Expected shape (see MihomoAPITypes.swift):
        //   ConnectionsResponse { downloadTotal, uploadTotal, connections: [Connection]? }
        //   Connection { id, metadata: Metadata, upload, download, start, chains, rule, rulePayload }
        //
        // Stub `http://127.0.0.1:9090/connections` with one entry, assert:
        //   - `resp.connections?.count == 1`
        //   - first connection's `metadata.host` and `metadata.destinationPort` round-trip
        //   - `chains` decodes as ordered array (reversed in the view)
        Issue.record("ConnectionsTests.getConnectionsHappyPath not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `GET /connections decodes empty-list payload (null connections)`() {
        // mihomo emits `"connections": null` when idle. Client must surface
        // `nil` (or `[]`) without throwing — `ConnectionsView` treats either
        // as "empty state" via `resp.connections ?? []`.
        Issue.record("ConnectionsTests.getConnectionsEmptyList not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `DELETE /connections/{id} issues correct verb and path`() {
        // Invoke `api.closeConnection(id: "abc-123")`, capture the outbound
        // URLRequest, assert `httpMethod == "DELETE"` and path ends with
        // `/connections/abc-123`. Swipe-to-close row in ConnectionsView
        // relies on this contract.
        Issue.record("ConnectionsTests.closeConnectionByID not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `DELETE /connections issues correct verb for close-all`() {
        // Toolbar "Close All" button in ConnectionsView calls
        // `api.closeAllConnections()`. Same stub harness as above but
        // targeting the collection URL (no id suffix).
        Issue.record("ConnectionsTests.closeAllConnections not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `non-2xx HTTP status surfaces as MihomoAPIError.http`() {
        // Stub `/connections` with 500 status; assert the thrown error
        // matches `MihomoAPIError.http(status: 500)`. Baseline behavior for
        // the error overlay the Connections Screen will add during T4.5.
        Issue.record("ConnectionsTests.httpErrorSurfaces not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `malformed JSON body surfaces as decoding error`() {
        // Stub `/connections` with `{"downloadTotal": "not-a-number"}`.
        // Swift's JSONDecoder must throw; client must propagate rather
        // than swallow. Polling loop in ConnectionsView.poll() currently
        // silently drops errors — T4.5 replaces that with an error banner.
        Issue.record("ConnectionsTests.malformedPayloadSurfaces not implemented — skeleton gated on T4.5")
    }
}
