import Foundation
@testable import meow_ios
import Testing

/// End-to-end contract for `ConnectionsView` (T4.5) — drives the view
/// against a stubbed `MihomoAPI` and asserts polling cadence, swipe-to-close
/// dispatch, Close-All dispatch, and search-filter behavior.
///
/// `.disabled("blocked on T4.5")` — this suite depends on two things the
/// T4.5 Connections Screen task delivers:
///
///   1. A hosted-view harness that can inject an `@Environment(MihomoAPI)`
///      into `ConnectionsView` and observe @State changes. The shared
///      harness lands with T4.5 (the Traffic / Subscriptions screens will
///      reuse it), so standing up a one-off fixture here would be churn.
///   2. Accessibility anchors on the Connections row (host/port, chain,
///      rule label) and the toolbar's "Close All" button. Today
///      `ConnectionsView.swift` has none — T4.5 is where the XCUITest
///      identifiers get wired for nightly E2E selection.
///
/// The skeletons here compile against `Connection` / `ConnectionsResponse`
/// (`App/Sources/Services/MihomoAPITypes.swift`) so contract drift breaks
/// the build before it reaches a reviewer.
///
/// `.serialized` — the MihomoAPI polling loop is long-lived; overlapping
/// tests against the same stub registry race on shared state.
@Suite("ConnectionsView — T4.5 screen contract", .tags(.screen), .serialized)
struct ConnectionsScreenTests {
    /// Compile-time anchor — drift in `Connection` / `ConnectionsResponse`
    /// or the close-connection API surface breaks this file.
    private static func _contractAnchor(api: MihomoAPI) async throws {
        _ = Connection.self
        _ = ConnectionsResponse.self
        _ = try await api.getConnections()
        try await api.closeConnection(id: "")
        try await api.closeAllConnections()
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `appears → polls /connections every ~1s`() {
        // Mount ConnectionsView with a stubbed API; count hits on the
        // `/connections` URL stub over a 3.5s window; expect 3–4 hits
        // (ConnectionsView.poll() sleeps 1s between calls). Catches any
        // regression to a run-once fetch when T4.5 adds pull-to-refresh.
        Issue.record("ConnectionsScreenTests.pollingCadence not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `swipe-to-close row dispatches DELETE /connections/{id}`() {
        // Seed stub with one `Connection { id: "abc-123", … }`; invoke the
        // row's swipe-action Close button via the harness; assert a
        // DELETE to `/connections/abc-123` was captured. Confirms the
        // id → URL binding in the row's swipeActions block.
        Issue.record("ConnectionsScreenTests.swipeToClose not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `Close-All toolbar button dispatches DELETE /connections`() {
        // Hit the toolbar's "Close All" affordance; assert
        // `api.closeAllConnections()` fired exactly once (DELETE on the
        // collection URL, no id suffix).
        Issue.record("ConnectionsScreenTests.closeAllToolbar not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `search query filters visible rows by metadata.host (case-insensitive)`() {
        // Seed three connections with hosts "example.com", "FOO.bar",
        // "speedtest.net"; set `query = "foo"`; assert only the FOO.bar
        // row is visible. Mirrors the `filtered` computed property;
        // locks the localizedCaseInsensitiveContains behavior in so
        // we don't silently regress to exact-match.
        Issue.record("ConnectionsScreenTests.searchFiltersByHost not implemented — skeleton gated on T4.5")
    }

    @Test(
        .disabled("blocked on T4.5"),
    )
    func `empty ConnectionsResponse renders zero rows without error overlay`() {
        // `{"downloadTotal":0,"uploadTotal":0,"connections":null}` — the
        // idle-tunnel payload. Assert List renders 0 rows and the nav
        // title shows "Connections (0)" with no error state.
        Issue.record("ConnectionsScreenTests.emptyStateNoError not implemented — skeleton gated on T4.5")
    }
}

extension Tag {
    @Tag static var screen: Self
}
