import XCTest

/// Not a test: the scripted walk through the app that the marketing film is
/// cut from. Skipped unless `SAFEKEY_PROMO=1` reaches the runner
/// (`TEST_RUNNER_SAFEKEY_PROMO=1 xcodebuild test …`), so ordinary runs never
/// spend time on it. The host records the simulator while it runs and finds
/// each shot by the timestamped markers this prints.
///
/// Every launch uses `--uitest`, so the demo vault lives in the scratch store
/// and a real vault on the device is never touched.
final class PromoTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 20

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SAFEKEY_PROMO"] == "1",
            "the promo tour only runs when asked for"
        )
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func mark(_ name: String) {
        print(String(format: "PROMO_MARK %@ %.3f", name, Date().timeIntervalSince1970))
    }

    private func hold(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// The iPhone tour: home, a private key revealed and hidden, a seed
    /// phrase, search, settings, then leaving and coming back through Face ID.
    func testTour() throws {
        app.launchArguments = ["--uitest", "--uitest-reset", "--promo", "--promo-visible-secrets"]
        app.launch()
        let all = app.buttons["tile.All"]
        try XCTSkipUnless(all.waitForExistence(timeout: timeout), "tile home not present — iPad layout")
        hold(1.5)

        mark("home")
        hold(3.0)
        app.swipeUp(velocity: .slow)
        mark("home-scrolled")
        hold(2.5)
        app.swipeDown(velocity: .slow)
        hold(1.5)

        all.tap()
        mark("list")
        hold(2.8)

        app.staticTexts["DeFi Vault"].tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        mark("detail-key")
        hold(2.4)
        secretRow.tap()
        mark("revealed-key")
        hold(3.2)
        secretRow.tap()
        mark("hidden-key")
        hold(1.4)
        back()
        hold(1.4)

        app.staticTexts["Main Wallet"].tap()
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        mark("detail-seed")
        hold(2.0)
        secretRow.tap()
        mark("revealed-seed")
        hold(3.6)
        secretRow.tap()
        hold(1.2)
        back()
        hold(1.0)
        back()
        hold(1.6)

        app.buttons["Settings"].tap()
        mark("settings")
        hold(3.0)
        app.swipeUp(velocity: .slow)
        mark("settings-scrolled")
        hold(2.6)
        app.buttons["Done"].firstMatch.tap()
        hold(1.6)

        XCUIDevice.shared.press(.home)
        mark("left")
        hold(2.4)
        app.activate()
        mark("returning")
        XCTAssertTrue(all.waitForExistence(timeout: timeout), "Face ID did not bring the vault back")
        mark("unlocked")
        hold(3.0)

        // Last, so the search never has to be dismissed.
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            search.typeText("cold")
            mark("search")
            hold(3.5)
        }
    }

    /// The Face ID moment on its own: a cold launch into the locked vault,
    /// held until the host posts a single match, then the vault opening. Run
    /// after `testTour`, which leaves the demo vault in the scratch store.
    func testFaceIDShot() throws {
        app.launchArguments = ["--uitest", "--promo", "--promo-visible-secrets"]
        app.launch()
        XCTAssertTrue(app.buttons["lock.biometrics"].waitForExistence(timeout: timeout))
        mark("lock-screen")
        XCTAssertTrue(app.buttons["tile.All"].waitForExistence(timeout: 30), "no Face ID match arrived")
        mark("unlocked")
        hold(3.0)
    }

    /// One still for the film's screenshot moment: the key revealed with the
    /// protection on, captured the way a screenshot captures it.
    func testProtectedScreenshot() throws {
        app.launchArguments = ["--uitest", "--uitest-reset", "--promo"]
        app.launch()
        let all = app.buttons["tile.All"]
        try XCTSkipUnless(all.waitForExistence(timeout: timeout), "tile home not present — iPad layout")
        all.tap()
        app.staticTexts["DeFi Vault"].tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        secretRow.tap()
        hold(1.5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "promo-protected-screenshot"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The iPad's split view, for the film's closing line-up of devices.
    func testTouriPad() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--uitest", "--uitest-reset", "--promo", "--promo-visible-secrets"]
        app.launch()
        try XCTSkipIf(app.buttons["tile.All"].waitForExistence(timeout: 8), "tile home present — iPhone layout")
        hold(1.5)
        mark("ipad-home")
        hold(2.5)
        app.staticTexts["DeFi Vault"].firstMatch.tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        mark("ipad-detail")
        hold(2.5)
        secretRow.tap()
        mark("ipad-revealed")
        hold(3.0)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "promo-ipad-revealed"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
