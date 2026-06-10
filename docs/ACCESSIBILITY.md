# meow-ios accessibility declaration

> **Status:** reflects the iOS 26 accessibility sprint completed 2026-06-10.
> Declaration targets Apple's App Store Accessibility Nutrition Labels.
> Sources: [App Store Connect overview](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/),
> [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
> [WWDC25 session 224](https://developer.apple.com/videos/play/wwdc2025/224/),
> [WWDC25 session 238](https://developer.apple.com/videos/play/wwdc2025/238/).

## Nutrition Label status

| Category | Status | Evidence |
|---|---|---|
| VoiceOver | **Supported** | Every interactive element in all primary views (HomeView, RulesEditorView, ProxyGroupsView, ConnectionsView, SubscriptionsView, SettingsView, YamlEditorView, LogsView, TrafficView, ProvidersView, DiagnosticsViewController, UserDiagnosticsView, ClashYAMLTextView, RuleEditorSheet) carries a concise `.accessibilityLabel`, correct traits, and operable double-tap; error banners post `AccessibilityNotification` on appearance; modal transitions post `AccessibilityNotification.screenChanged`; decorative icons are hidden. |
| Voice Control | **Supported** | Every tappable element has a unique, visible or `.accessibilityLabel`-derived name; duplicate "Test" buttons in UserDiagnosticsView were disambiguated; no required action is hidden behind an unlabeled gesture (previously unreachable badge taps in ProxyGroupsView and reorder/delete in RulesEditorView are exposed as named custom actions). |
| Larger Text | **Supported** | All body text uses Dynamic Type semantic styles; ClashYAMLTextView's previously hard-coded 14 pt / 11 pt fonts are now scaled via `UIFontMetrics` with a `UITraitPreferredContentSizeCategory` re-apply hook; no fixed-size text remains in primary views. |
| Dark Interface | **Supported** | The app uses SwiftUI Material / `.glass` backgrounds and system-adaptive colors throughout; all views are verified to render with a predominantly dark background in Dark Mode with all content and controls perceivable. |
| Differentiate Without Color | **Supported** | ProxyGroupsView and ProvidersView read `@Environment(\.accessibilityDifferentiateWithoutColor)` and inject checkmark/exclamation SF Symbols alongside latency color coding; TrafficView renders the upload series as a dashed line when the flag is on; ClashYAMLTextView draws an exclamation glyph in the error gutter instead of a color-only red dot. |
| Sufficient Contrast | **Partially supported** | The app relies on system Material backgrounds and SwiftUI default label colors, which pass 4.5:1 in standard and high-contrast modes. A systematic contrast audit against Apple's Increase Contrast + Bold Text matrix for custom-tinted elements (delay badges, status colors) has not been completed; this category should not be declared until that audit closes. |
| Reduced Motion | **Supported** | LogsView auto-scroll skips `withAnimation` when `accessibilityReduceMotion` is on; ProxyGroupsView expand/collapse animation is gated on the same flag; no other view in the primary task flows uses mandatory animations. |
| Captions | **Not applicable** | meow-ios contains no video or audio content that is part of a common task; the intro video (`meow-intro.mp4`) is a marketing asset shown only on the App Store page, not inside the app. |
| Audio Descriptions | **Not applicable** | Same rationale as Captions — no in-app video content. |

## How we test

**VoiceOver smoke pass** — enable VoiceOver in Settings > Accessibility, then walk through the six primary task flows (connect/disconnect, add/edit/delete a rule, switch proxy group, view connections, update a subscription, edit YAML config) using only swipe navigation and double-tap activation. Each flow must complete without requiring a sighted fallback. Run on device; simulator VoiceOver is not representative.

**Dynamic Type** — set Accessibility > Display & Text Size > Larger Text to the maximum accessibility size (AX5), then open each primary view and confirm no text is truncated to a single character and no controls overlap to the point of being untappable. Repeat at default size to catch regression.

**Reduce Motion** — enable Settings > Accessibility > Motion > Reduce Motion, open LogsView with active log output and ProxyGroupsView with multiple expanded groups; confirm no spinning or sliding animations play and all content remains reachable.

**Differentiate Without Color** — enable Settings > Accessibility > Display & Text Size > Differentiate Without Color; open ProvidersView, ProxyGroupsView, TrafficView, and ClashYAMLTextView; confirm every color-coded indicator has a visible shape/symbol companion.

**CI gap** — no automated accessibility tests run in CI today. The `MeowUITests` target covers tab navigation but does not assert on `accessibilityLabel` values or VoiceOver traversal order; adding `XCUIAccessibilityAudit` assertions is tracked as a future improvement.

## Declaring in App Store Connect

1. Open [App Store Connect](https://appstoreconnect.apple.com) and navigate to **Apps > meow > App Information**.
2. Scroll to the **Accessibility** section and click **Edit**.
3. For each category below, select the matching option in the picker:

   | Nutrition Label | Select |
   |---|---|
   | VoiceOver | Supported |
   | Voice Control | Supported |
   | Larger Text | Supported |
   | Dark Interface | Supported |
   | Differentiate Without Color | Supported |
   | Sufficient Contrast | *(leave unchecked until contrast audit completes)* |
   | Reduced Motion | Supported |
   | Captions | Not Applicable |
   | Audio Descriptions | Not Applicable |

4. Save and include the updated App Information in the next version submission. Nutrition Label selections are version-specific — they must be re-confirmed on each new version record.
