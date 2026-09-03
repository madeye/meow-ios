import Foundation
@testable import meow_ios
import Testing
import UIKit

@Suite("AppIcon model")
struct AppIconTests {
    @Test
    func `primary maps to a nil alternate icon name`() {
        #expect(AppIcon.primary.alternateIconName == nil)
    }

    @Test
    func `alternate icons pass their asset name to UIKit`() {
        #expect(AppIcon.leap.alternateIconName == "AppIconLeap")
        #expect(AppIcon.sunset.alternateIconName == "AppIconSunset")
        #expect(AppIcon.midnight.alternateIconName == "AppIconMidnight")
    }

    @Test
    func `every case round-trips through alternateIconName`() {
        // `UIApplication.alternateIconName` is the only persistence for the
        // icon choice — the picker restores its selection through this init,
        // so the mapping must be lossless for every case.
        for icon in AppIcon.allCases {
            #expect(AppIcon(alternateIconName: icon.alternateIconName) == icon)
        }
    }

    @Test
    func `unknown or stale icon names fall back to primary`() {
        #expect(AppIcon(alternateIconName: "RemovedInSomeUpdate") == .primary)
    }

    @Test
    func `asset names, preview names and title keys are unique across cases`() {
        let cases = AppIcon.allCases
        #expect(Set(cases.map(\.rawValue)).count == cases.count)
        #expect(Set(cases.map(\.previewAssetName)).count == cases.count)
        #expect(Set(cases.map(\.titleKey)).count == cases.count)
    }

    @Test
    func `every title key resolves in the en strings catalogue`() throws {
        // `Bundle.main` is the host app bundle (see LocalizableParityTests);
        // zh-Hans coverage follows from the en ⇄ zh-Hans parity suite.
        let path = try #require(Bundle.main.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: "en",
        ))
        let table = NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
        for icon in AppIcon.allCases {
            #expect(table[icon.titleKey] != nil, "missing en string for \(icon.titleKey)")
        }
    }

    @MainActor
    @Test
    func `every case has a preview image in the asset catalogue`() {
        // AppIconPickerView renders these; a missing imageset would leave a
        // blank row with no other symptom (SwiftUI's Image fails silently).
        for icon in AppIcon.allCases {
            #expect(
                UIImage(named: icon.previewAssetName) != nil,
                "missing \(icon.previewAssetName).imageset for \(icon.rawValue)",
            )
        }
    }

    @MainActor
    @Test
    func `every case has a status-glyph image in both connection states`() {
        // VpnStatusGlyph mirrors the installed icon; a missing asset would
        // blank the Home tab's leading glyph and nothing else.
        for icon in AppIcon.allCases {
            for connected in [true, false] {
                let name = icon.glyphAssetName(connected: connected)
                #expect(UIImage(named: name) != nil, "missing \(name) for \(icon.rawValue)")
            }
        }
    }

    @Test
    func `only the pre-masked primary mascot skips the glyph squircle`() {
        // AppMark's squircle lives in its alpha channel; masking it a second
        // time would clip the artwork instead of shaping it.
        #expect(AppIcon.primary.glyphCornerRadiusRatio == 0)
        for icon in AppIcon.allCases where icon != .primary {
            #expect(icon.glyphCornerRadiusRatio == AppIcon.squircleRadiusRatio)
        }
    }

    @Test
    func `every alternate icon is registered in the processed Info plist`() throws {
        // actool copies ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES
        // (project.yml) into CFBundleIcons → CFBundleAlternateIcons. Adding a
        // case + .appiconset but forgetting the build setting compiles fine
        // and then fails at runtime, when setAlternateIconName(_:) throws.
        // The app is universal, so actool writes an iPad-suffixed variant too;
        // which key is populated depends on the simulator the suite runs on.
        let icons = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons~ipad") as? [String: Any],
        )
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        for name in AppIcon.allCases.compactMap(\.alternateIconName) {
            #expect(alternates[name] != nil, "\(name) is missing from CFBundleAlternateIcons")
        }
    }
}
