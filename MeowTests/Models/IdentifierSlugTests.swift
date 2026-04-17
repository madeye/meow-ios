import Testing
import Foundation
import MeowModels

/// Contract for `String.identifierSlug` (MeowShared/MeowModels) — the
/// slug used to build XCUITest `accessibilityIdentifier`s on the Home
/// Screen (e.g. `home.group.<slug>`, `home.proxy.<group>.<proxy>`).
///
/// Two sides depend on byte-for-byte agreement:
///   - `App/Sources/Views/HomeView.swift` renders `accessibilityIdentifier(…)`
///     with the slug applied to the Mihomo group / proxy display name.
///   - `MeowUITests/Support/VPhone.swift` builds the same identifiers
///     in `HomeScreen.AccessibilityID.{group,proxy}` via the shared
///     extension below, so the XCUITest selectors match what the view
///     layer rendered.
///
/// If either side drifts, this file fails — which is preferable to the
/// alternative of silently-mismatched identifiers producing "element
/// not found" errors at nightly E2E time.
@Suite("identifierSlug — home.group / home.proxy slug contract", .tags(.model))
struct IdentifierSlugTests {

    @Test("ASCII lowercase passes through unchanged")
    func passthrough() {
        #expect("auto".identifierSlug == "auto")
        #expect("direct".identifierSlug == "direct")
        #expect("reject".identifierSlug == "reject")
    }

    @Test("uppercase folds to lowercase, digits preserved")
    func caseFold() {
        #expect("ALLCAPS".identifierSlug == "allcaps")
        #expect("Hong Kong 01".identifierSlug == "hong-kong-01")
        #expect("Node42".identifierSlug == "node42")
    }

    @Test("non-ASCII letters and emoji collapse to dash boundaries")
    func nonAscii() {
        // Dev's T4.2 example — regional-indicator flag + spaces.
        #expect("🇺🇸 US Nodes".identifierSlug == "us-nodes")
        #expect("Speedtest.net ⚡️".identifierSlug == "speedtest-net")
        #expect("东京 01".identifierSlug == "01")
    }

    @Test("leading / trailing / repeated non-alphanumerics collapse cleanly")
    func dashCollapsing() {
        #expect("  hello  world  ".identifierSlug == "hello-world")
        #expect("...dots...".identifierSlug == "dots")
        #expect("a--b".identifierSlug == "a-b")
    }

    @Test("empty or all-non-ASCII input yields the '_' sentinel")
    func emptySentinel() {
        #expect("".identifierSlug == "_")
        #expect("---".identifierSlug == "_")
        #expect("🇺🇸".identifierSlug == "_")
        #expect("   ".identifierSlug == "_")
    }
}

