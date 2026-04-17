import XCTest

/// Accessibility smoke tests. Iterates every visible interactive element
/// and asserts a non-empty `accessibilityLabel`. See TEST_STRATEGY §5.2.
final class AccessibilityTests: XCTestCase {
    func testAllButtonsHaveLabels() throws {
        throw XCTSkip("blocked on T5.1 app shell")
        // traverse each tab → assert every button has .label != ""
    }

    func testDynamicTypeXXXLRendersWithoutClipping() throws {
        throw XCTSkip("blocked on T5.1 + accessibility audit")
        // set UIContentSizeCategoryAccessibilityExtraExtraExtraLarge via launch arg
        // walk screens, check no obvious clipping via snapshot comparison
    }

    func testDarkModeRendersGlassCardsReadably() throws {
        throw XCTSkip("blocked on T6.1 glass UI pass")
    }

    func testIpadSidebarLayout() throws {
        throw XCTSkip("blocked on T5.1 iPad split layout")
    }
}
