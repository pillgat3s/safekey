import XCTest

/// Not a test: captures the inner display of an iPhone Duo in both
/// orientations, from the demo vault, for review and for the App Store.
/// Skipped unless `SAFEKEY_DUO_STILLS=1` reaches the runner
/// (`TEST_RUNNER_SAFEKEY_DUO_STILLS=1 xcodebuild … test`), and only
/// meaningful on an iPhone Duo simulator that Device Hub has opened.
///
/// PNGs land in the runner's temporary directory under `DuoStills`:
///   xcrun simctl get_app_container <udid> com.andri.safekey.uitests.ios.xctrunner data
final class DuoStillsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 20

    private var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DuoStills", isDirectory: true)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SAFEKEY_DUO_STILLS"] == "1",
            "Duo stills only run when asked for"
        )
        continueAfterFailure = false
        app = XCUIApplication()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Every screen, not just the main one: on an open iPhone Duo the main
    /// screen is still the outer display, which is dark, and the inner
    /// display is the second entry. Each goes out under its own suffix.
    private func capture(_ name: String) {
        settle()
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let shot = screen.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name)-screen\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try? shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name)-screen\(index).png"))
        }
    }

    func testCaptureInnerDisplay() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--uitest", "--uitest-reset", "--promo", "--promo-visible-secrets"]
        app.launch()
        // The inner display is regular in both directions, so the sidebar
        // layout is up; the tile home means the device is closed.
        try XCTSkipIf(app.buttons["tile.All"].waitForExistence(timeout: 8), "tile home present — the device is closed")
        XCTAssertTrue(app.staticTexts["Daily Burner"].firstMatch.waitForExistence(timeout: timeout))
        capture("duo-inner-portrait-home")

        app.staticTexts["Daily Burner"].firstMatch.tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        secretRow.tap()
        capture("duo-inner-portrait-detail")

        XCUIDevice.shared.orientation = .landscapeLeft
        settle(1.5)
        capture("duo-inner-landscape-detail")
        // The sidebar is on screen too, so the first bar button anywhere is
        // its Settings gear; ask for the detail column's Back by name.
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        capture("duo-inner-landscape-home")
    }
}
