import XCTest

/// Layout in the configurations the app claims to support.
///
/// The Info.plist allows landscape and the target ships for iPad, so both are
/// promises the app has to keep. Screens built from a VStack with spacers are
/// exactly the ones that break when the height halves, so these capture the
/// short-height case for review as well as asserting the controls survive.
final class LayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 25
    private let masterPassword = "Correct-Horse-9"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-reset"]
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        super.tearDown()
    }

    func testLandscapeKeepsEveryControlReachable() {
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        // Onboarding: the tallest screen, and the first one a user ever sees.
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout))
        captureScreen("landscape-01-onboarding")
        XCTAssertTrue(password.isHittable, "the password field must be reachable in landscape")

        password.tap()
        password.typeText(masterPassword)
        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText(masterPassword)

        let create = app.buttons["Create Vault"]
        XCTAssertTrue(create.exists)
        // Scrollable, so it may sit below the fold — what matters is that it can
        // be brought into view rather than being stranded off-screen.
        if !create.isHittable { app.swipeUp() }
        create.tap()

        XCTAssertTrue(app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout))
        captureScreen("landscape-02-empty-vault")

        // The lock screen is a VStack with spacers — the one most at risk.
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: timeout))
        app.buttons["Lock"].tap()

        let lockField = app.secureTextFields["lock.password"]
        XCTAssertTrue(lockField.waitForExistence(timeout: timeout))
        captureScreen("landscape-03-lock-screen")
        XCTAssertTrue(lockField.isHittable, "the lock screen password field must be reachable in landscape")

        lockField.tap()
        lockField.typeText(masterPassword + "\n")
        XCTAssertTrue(
            app.navigationBars["All Wallets"].waitForExistence(timeout: timeout),
            "unlocking must work in landscape"
        )
        captureScreen("landscape-04-wallet-list")
    }
}
