import Foundation
import Testing

/// Guards against silent key drift between `en.lproj/Localizable.strings`
/// (developmentRegion) and `zh-Hans.lproj/Localizable.strings`. The two
/// catalogues must share the same key set — if a SwiftUI view introduces
/// `Text("foo.bar")` but only `en.lproj` carries the value, a zh-CN
/// device renders the raw key string. The reverse (zh-Hans with an extra
/// key) is dead weight that won't survive a translator pass.
///
/// Test runs against the host app bundle, so `Bundle.main` here is the
/// `meow-ios.app` (unit-test target is hosted by the app target).
@Suite("Localizable.strings parity (en ⇄ zh-Hans)")
struct LocalizableParityTests {
    @Test
    func `en and zh-Hans share an identical key set`() throws {
        let en = try loadStrings(localization: "en")
        let zh = try loadStrings(localization: "zh-Hans")

        let enKeys = Set(en.keys)
        let zhKeys = Set(zh.keys)
        let missingFromZh = enKeys.subtracting(zhKeys).sorted()
        let extraInZh = zhKeys.subtracting(enKeys).sorted()
        #expect(
            missingFromZh.isEmpty,
            "zh-Hans is missing keys present in en.lproj: \(missingFromZh)",
        )
        #expect(
            extraInZh.isEmpty,
            "zh-Hans has keys absent from en.lproj (orphans): \(extraInZh)",
        )
    }

    @Test
    func `every zh-Hans value is non-empty`() throws {
        let zh = try loadStrings(localization: "zh-Hans")
        let empties = zh.filter(\.value.isEmpty).keys.sorted()
        #expect(empties.isEmpty, "zh-Hans has empty values for keys: \(empties)")
    }

    @Test
    func `printf format specifiers match across locales`() throws {
        // If en has "Total %@" and zh translates that to "合计 %lld" the
        // runtime crashes when SwiftUI feeds it a string argument. Compare
        // the multiset of conversion specifiers (%@, %lld, %d, %f, %1$@,
        // …) per key.
        let en = try loadStrings(localization: "en")
        let zh = try loadStrings(localization: "zh-Hans")
        for (key, enValue) in en {
            guard let zhValue = zh[key] else { continue } // covered by key-set test
            let enSpecs = formatSpecifiers(in: enValue).sorted()
            let zhSpecs = formatSpecifiers(in: zhValue).sorted()
            #expect(
                enSpecs == zhSpecs,
                "Format specifier mismatch for '\(key)': en=\(enSpecs) zh=\(zhSpecs)",
            )
        }
    }

    // MARK: - Helpers

    private func loadStrings(localization: String) throws -> [String: String] {
        // `Bundle.main` is the host app's bundle when run from a unit-test
        // target hosted by an iOS app target.
        guard let path = Bundle.main.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: localization,
        ) else {
            Issue.record("Could not locate Localizable.strings for '\(localization)' in host bundle")
            return [:]
        }
        let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        return dict ?? [:]
    }

    /// Extract printf-style conversion specifiers from a format string.
    /// Returns the literal `%@`, `%lld`, `%d`, `%f`, `%1$@`, … tokens —
    /// `%%` (literal percent) is skipped. Conservative regex that accepts
    /// the subset Foundation actually emits in Localizable.strings.
    private func formatSpecifiers(in value: String) -> [String] {
        // %% must not be counted, so consume it first and ignore.
        // Then match %[positional$][length-flag]conversion.
        let pattern = #"%(?:[0-9]+\$)?(?:[-+#0 ]?[0-9]*)?(?:l{1,2}|h{1,2}|q|z|j|t)?[@diouxXeEfgGsScCp%]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = value as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: value, range: range)
            .map { ns.substring(with: $0.range) }
            .filter { $0 != "%%" }
    }
}
