import Foundation

public extension String {
    /// Identifier-safe slug used in XCUITest `accessibilityIdentifier`s
    /// (e.g. `home.group.<slug>`, `home.proxy.<group>.<proxy>`).
    /// Lowercases ASCII letters, keeps digits, and collapses anything
    /// outside `[a-z0-9]` into single `-` separators. Leading and
    /// trailing dashes are stripped; an empty result (all non-ASCII
    /// input) becomes `"_"` so the identifier is never empty.
    ///
    /// Pure — no locale-aware casing, no Unicode normalisation beyond
    /// the ASCII-digit/letter check — so the app's rendering side
    /// (`App/Sources/Views/HomeView.swift`, which prior to consolidation
    /// carried a private copy of this function) and the test bundle's
    /// selector-builder side always agree on the exact same bytes.
    ///
    /// Contract-tested in `MeowTests/IdentifierSlugTests.swift` against
    /// the known input/output pairs the E2E nightly depends on.
    var identifierSlug: String {
        var out = ""
        var trailingDash = true
        for scalar in unicodeScalars {
            let v = scalar.value
            let isLower = v >= 0x61 && v <= 0x7A
            let isUpper = v >= 0x41 && v <= 0x5A
            let isDigit = v >= 0x30 && v <= 0x39
            if isDigit || isLower {
                out.append(Character(scalar))
                trailingDash = false
            } else if isUpper {
                out.append(Character(Unicode.Scalar(v + 0x20)!))
                trailingDash = false
            } else if !trailingDash {
                out.append("-")
                trailingDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "_" : out
    }
}
