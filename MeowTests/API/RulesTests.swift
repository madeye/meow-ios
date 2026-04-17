import Foundation
@testable import meow_ios
import Testing

/// Contract for `GET /rules` — consumed by T4.6 Rules Screen.
///
/// `.disabled("blocked on T4.6")` until the URLProtocolStub harness for
/// the `@Observable` `MihomoAPI` is shared across API suites (lands with
/// the T4.6 Rules Screen work). Today these skeletons serve as a
/// compile-time contract check against `Rule` / `RulesResponse` in
/// `App/Sources/Services/MihomoAPITypes.swift`: if either shape drifts,
/// this file fails to build.
///
/// Fixture source: `URLProtocolStub` in `MeowTests/Support/URLProtocolStub.swift`.
@Suite("MihomoAPI rules endpoint", .tags(.api))
struct RulesTests {
    /// Compile-time anchor — drift in `Rule` / `RulesResponse` or in the
    /// `getRules()` signature breaks this file.
    private static func _contractAnchor(api: MihomoAPI) async throws {
        _ = Rule.self
        _ = RulesResponse.self
        _ = try await api.getRules()
    }

    @Test(
        .disabled("blocked on T4.6"),
    )
    func `GET /rules parses Rule array with type/payload/proxy triples`() {
        // Expected shape (MihomoAPITypes.swift):
        //   RulesResponse { rules: [Rule] }
        //   Rule { type, payload, proxy, id: "\(type)\(payload)\(proxy)" }
        //
        // Stub `http://127.0.0.1:9090/rules` with a three-entry mix of
        // DOMAIN-SUFFIX / GEOIP / MATCH rules; assert each decodes and
        // `rule.id` is unique across the list (RulesView relies on
        // Identifiable for ForEach).
        Issue.record("RulesTests.getRulesHappyPath not implemented — skeleton gated on T4.6")
    }

    @Test(
        .disabled("blocked on T4.6"),
    )
    func `GET /rules handles empty rules list`() {
        // Fresh config with no rules yet: `{"rules":[]}`. Decoder must
        // yield `RulesResponse(rules: [])`, not throw. RulesView renders
        // empty List without error overlay.
        Issue.record("RulesTests.getRulesEmpty not implemented — skeleton gated on T4.6")
    }

    @Test(
        .disabled("blocked on T4.6"),
    )
    func `non-2xx HTTP status surfaces as MihomoAPIError.http`() {
        // Stub `/rules` with 503; the `.overlay` showing error text in
        // RulesView depends on this being a throwing path rather than a
        // silent empty-list.
        Issue.record("RulesTests.httpErrorSurfaces not implemented — skeleton gated on T4.6")
    }

    @Test(
        .disabled("blocked on T4.6"),
    )
    func `unknown rule type string preserves raw value (no enum coercion)`() {
        // mihomo adds new rule kinds upstream faster than we ship; `Rule.type`
        // is `String` not an enum so new kinds pass through unchanged.
        // Guards against a well-meaning enum refactor that would start
        // rejecting valid server payloads.
        Issue.record("RulesTests.unknownRuleTypePreserved not implemented — skeleton gated on T4.6")
    }
}
