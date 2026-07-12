import Foundation
@testable import meow_ios
import Testing
import UIKit

/// QR bitmap generation for the export sheet: real share-link payloads render,
/// module edges stay crisp under integer scaling, and over-capacity payloads
/// fail soft (nil → the sheet shows its too-long notice instead of a QR).
@Suite("QR code renderer", .tags(.service))
struct QRCodeRendererTests {
    @Test
    func `renders a scannable-size image for a share link`() throws {
        let uri = "ss://YWVzLTEyOC1nY206c2VjcmV0@example.com:8443#Node"
        let image = try #require(QRCodeRenderer.image(for: uri))
        // 12pt per module and a Version-lucky payload still lands well above
        // the ~200px floor scanners want.
        #expect(image.size.width >= 200)
        #expect(image.size.width == image.size.height)
    }

    @Test
    func `renders subscription URLs with query parameters`() {
        let url = "https://sub.example.com/api/v1/client/subscribe?token=abc123&flag=clash"
        #expect(QRCodeRenderer.image(for: url) != nil)
    }

    @Test
    func `returns nil when the payload exceeds QR capacity`() {
        // Level-M byte capacity tops out at 2331 bytes (Version 40).
        let oversized = String(repeating: "x", count: 3000)
        #expect(QRCodeRenderer.image(for: oversized) == nil)
    }
}
