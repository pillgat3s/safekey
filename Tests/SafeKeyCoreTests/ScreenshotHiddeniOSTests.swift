#if os(iOS)
import XCTest
import SwiftUI
@testable import SafeKeyiOS

/// The revealed secret is drawn on the layer iOS keeps out of screenshots and
/// recordings. That layer is borrowed from a secure text field's rendering
/// canvas, which is a detail of UIKit's view hierarchy rather than a contract:
/// this test fails the moment an iOS release stops exposing it, which is the
/// moment the protection would otherwise fall away silently.
@MainActor
final class ScreenshotHiddeniOSTests: XCTestCase {
    func testRevealedContentSitsOnTheSecureCanvas() {
        let host = SecureCanvasHost(rootView: Text("0xabc"))
        XCTAssertTrue(host.isProtected, "the secure text-field canvas was not found; screenshots would show the secret")
    }

    func testHostReportsItsContentSize() {
        let host = SecureCanvasHost(rootView: Text("0xabc").font(.body))
        let size = host.size(fitting: ProposedViewSize(width: 300, height: nil))
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(size.width, 300)
    }
}
#endif
