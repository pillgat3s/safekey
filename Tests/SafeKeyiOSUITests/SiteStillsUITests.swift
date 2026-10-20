import XCTest

/// Not a test: captures the screens the website shows, from the demo vault.
/// Skipped unless `SAFEKEY_SITE_STILLS=1` reaches the runner
/// (`TEST_RUNNER_SAFEKEY_SITE_STILLS=1 xcodebuild … test-without-building`),
/// so ordinary runs never spend time on it.
///
/// PNGs land in the runner's temporary directory under `SiteStills`, which the
/// host finds with:
///   xcrun simctl get_app_container <udid> com.andri.safekey.uitests.ios.xctrunner data
final class SiteStillsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 20
    private let masterPassword = "Correct-Horse-9"

    private var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SiteStills", isDirectory: true)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SAFEKEY_SITE_STILLS"] == "1",
            "site stills only run when asked for"
        )
        continueAfterFailure = false
        app = XCUIApplication()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.8) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ name: String) {
        settle()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testCaptureSiteStills() throws {
        // Unlocked, with secrets visible to the capture.
        app.launchArguments = ["--uitest", "--uitest-reset", "--promo", "--promo-visible-secrets"]
        app.launch()
        let all = app.buttons["tile.All"]
        try XCTSkipUnless(all.waitForExistence(timeout: timeout), "tile home not present — iPad layout")
        capture("iphone-home")

        all.tap()
        XCTAssertTrue(app.staticTexts["Airdrop Farm A"].waitForExistence(timeout: timeout))
        capture("iphone-list")

        app.staticTexts["Airdrop Farm A"].tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        capture("iphone-key-masked")
        secretRow.tap()
        settle(0.6)
        capture("iphone-key-revealed")
        back()

        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: timeout))
        app.staticTexts["Daily Burner"].tap()
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        secretRow.tap()
        settle(0.6)
        capture("iphone-seed-revealed")

        // A cold launch into the vault the first run left behind: locked, and
        // without the capture exemption, so a revealed secret comes out blank.
        app.terminate()
        app.launchArguments = ["--uitest", "--promo"]
        app.launch()
        let password = app.secureTextFields["lock.password"]
        if password.waitForExistence(timeout: 8) {
            capture("iphone-lock")
            password.tap()
            password.typeText(masterPassword + "\n")
        }
        XCTAssertTrue(all.waitForExistence(timeout: timeout), "the vault did not unlock")
        all.tap()
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: timeout))
        app.staticTexts["Daily Burner"].tap()
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        secretRow.tap()
        settle(0.6)
        capture("iphone-seed-protected")
    }
}
