import Foundation
@testable import meow_ios
import Testing

/// Contract for the Connections half of the meow REST client (T3.4) — the
/// slice consumed by T4.5 Connections Screen.
///
/// The `.disabled("blocked on T4.5")` attribute is deliberate: the REST
/// methods already exist on `MeowAPI`, but the full URLProtocolStub
/// harness for the `@Observable` client (shared with `MeowAPITests.swift`)
/// lands with T4.5 when the Connections Screen goes through end-to-end
/// wiring. Until then these tests exist to:
///
///   1. Compile against today's `Connection` / `ConnectionsResponse`
///      contract from `App/Sources/Services/MeowAPITypes.swift` — if any
///      field gets renamed or retyped, this file fails to build (the point
///      of skeleton tests, per team-lead).
///   2. Pin the endpoint list T4.5 must satisfy: polling `/connections`,
///      `DELETE /connections/{id}`, `DELETE /connections`, plus empty-list
///      and HTTP-error handling.
///
/// Fixture source: `URLProtocolStub` in `MeowTests/Support/URLProtocolStub.swift`.
@Suite("MeowAPI connections endpoints", .tags(.api))
struct ConnectionsTests {
    /// Compile-time anchor: if any of the shapes below drifts, this file
    /// fails to build. That is the point of skeleton tests.
    private static func _contractAnchor(api: MeowAPI) async throws {
        _ = ConnectionsResponse.self
        _ = Connection.self
        _ = Connection.Metadata.self
        _ = MeowAPIError.http(status: 0)
        _ = try await api.getConnections()
        try await api.closeConnection(id: "")
        try await api.closeAllConnections()
    }

    /// Wire-accurate regression fixture for the "连接 (0)" decode failure:
    /// meow-rs 498967e serializes per-connection `metadata` (meow-rs#241)
    /// with ports as JSON numbers (`u16`), nullable `sourceIP`/
    /// `destinationIP`, and extra fields (`dnsMode`, geo-IP arrays, …).
    /// The old Swift model decoded `destinationPort` as `String` and the
    /// IPs as non-optional, so one active connection made the WHOLE
    /// payload undecodable — same failure mode as `Proxy.History.time`
    /// (issue #255). This fixture is copied from what
    /// `ConnectionInfo`/`Metadata`'s `Serialize` derives actually emit.
    @Test func `decodes engine /connections payload with numeric ports and null IPs`() throws {
        let resp = try JSONDecoder().decode(
            ConnectionsResponse.self,
            from: Data(Self.engineFixture.utf8),
        )
        #expect(resp.downloadTotal == 3_842_146)
        #expect(resp.uploadTotal == 486_539)
        let conns = try #require(resp.connections)
        #expect(conns.count == 2)
        #expect(conns[0].metadata?.host == "www.gstatic.com")
        #expect(conns[0].metadata?.destinationPort == "443")
        #expect(conns[0].chains == ["nx", "Proxy"])
        // Direct-IP connection: empty host, IP survives for display.
        #expect(conns[1].metadata?.host.isEmpty == true)
        #expect(conns[1].metadata?.destinationIP == "142.250.72.14")
        #expect(conns[1].metadata?.destinationPort == "8443")
        #expect(conns[1].metadata?.network == "udp")
    }

    private static let engineFixture = """
    {
      "upload_total": 486539,
      "download_total": 3842146,
      "connections": [
        {
          "id": "0193b1de-7e47-7c1a-8f2e-4babbe1f48da",
          "metadata": {
            "network": "tcp",
            "type": "Https",
            "sourceIP": "172.19.0.1",
            "destinationIP": null,
            "sourcePort": 54321,
            "destinationPort": 443,
            "host": "www.gstatic.com",
            "dnsMode": "fake-ip",
            "process": "",
            "processPath": "",
            "uid": null,
            "sourceGeoIP": [],
            "destinationGeoIP": [],
            "sniffHost": "",
            "inboundName": "tun",
            "inboundPort": 0,
            "specialProxy": ""
          },
          "upload": 42496,
          "download": 384000,
          "start": "1783779180",
          "chains": ["nx", "Proxy"],
          "rule": "MATCH",
          "rulePayload": ""
        },
        {
          "id": "0193b1de-8f2e-7c1a-7e47-4babbe1f48db",
          "metadata": {
            "network": "udp",
            "type": "Socks5",
            "sourceIP": null,
            "destinationIP": "142.250.72.14",
            "sourcePort": 0,
            "destinationPort": 8443,
            "host": "",
            "dnsMode": "normal",
            "process": "",
            "processPath": "",
            "uid": null,
            "sourceGeoIP": [],
            "destinationGeoIP": [],
            "sniffHost": "",
            "inboundName": "tun",
            "inboundPort": 0,
            "specialProxy": ""
          },
          "upload": 189,
          "download": 965,
          "start": "1783779181",
          "chains": ["nx"],
          "rule": "GEOIP",
          "rulePayload": "CN"
        }
      ]
    }
    """

    /// mihomo-compat panels get string ports from the classic API; the
    /// tolerant decoder must keep accepting those too.
    @Test func `decodes mihomo-compat string ports and missing metadata`() throws {
        let resp = try JSONDecoder().decode(
            ConnectionsResponse.self,
            from: Data(Self.compatFixture.utf8),
        )
        let conns = try #require(resp.connections)
        #expect(conns[0].metadata?.destinationPort == "443")
        #expect(conns[1].metadata == nil)
    }

    private static let compatFixture = """
    {
      "upload_total": 0,
      "download_total": 0,
      "connections": [
        {
          "id": "a",
          "metadata": {
            "network": "tcp",
            "host": "github.com",
            "destinationPort": "443"
          },
          "upload": 0,
          "download": 0,
          "start": "1783779180",
          "chains": [],
          "rule": "MATCH",
          "rulePayload": ""
        },
        {
          "id": "b",
          "upload": 0,
          "download": 0,
          "start": "1783779180",
          "chains": [],
          "rule": "MATCH",
          "rulePayload": ""
        }
      ]
    }
    """

    /// Idle engine emits `"connections": null` — must decode as nil, not throw.
    @Test func `decodes null connections list`() throws {
        let fixture = """
        {"upload_total": 0, "download_total": 0, "connections": null}
        """
        let resp = try JSONDecoder().decode(
            ConnectionsResponse.self,
            from: Data(fixture.utf8),
        )
        #expect(resp.connections == nil)
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `GET /connections decodes ConnectionsResponse with non-empty list`() {
        // Expected shape (see MeowAPITypes.swift):
        //   ConnectionsResponse { downloadTotal, uploadTotal, connections: [Connection]? }
        //   Connection { id, metadata: Metadata, upload, download, start, chains, rule, rulePayload }
        //
        // Stub `http://127.0.0.1:<port>/connections` with one entry, assert:
        //   - `resp.connections?.count == 1`
        //   - first connection's `metadata.host` and `metadata.destinationPort` round-trip
        //   - `chains` decodes as ordered array (reversed in the view)
        Issue.record("ConnectionsTests.getConnectionsHappyPath not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `GET /connections decodes empty-list payload (null connections)`() {
        // meow emits `"connections": null` when idle. Client must surface
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
    func `non-2xx HTTP status surfaces as MeowAPIError.http`() {
        // Stub `/connections` with 500 status; assert the thrown error
        // matches `MeowAPIError.http(status: 500)`. Baseline behavior for
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
