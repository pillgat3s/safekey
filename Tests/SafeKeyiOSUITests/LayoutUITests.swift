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

    /// First run opens on the welcome screen now.
    private func dismissWelcome() {
        let cont = app.buttons["welcome.continue"]
        if cont.waitForExistence(timeout: 15) { cont.tap() }
    }

    /// A freshly created vault now offers biometric unlock. Tests that are not
    /// about biometrics decline it, so the alert does not sit over the UI.
    private func declineBiometricOffer() {
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
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
        dismissWelcome()
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

        // The iPhone lands on the tile home; an iPad lands on the split view,
        // whose preselected All list shows its own empty state.
        let landed = app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout)
            || app.staticTexts["Nothing Here"].waitForExistence(timeout: timeout)
        XCTAssertTrue(landed, "vault creation did not land on an empty vault")
        declineBiometricOffer()
        captureScreen("landscape-02-empty-vault")

        // The lock screen is a VStack with spacers — the one most at risk.
        // The vault locks by leaving the foreground; there is no manual lock.
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 15)
        app.activate()

        let lockField = app.secureTextFields["lock.password"]
        XCTAssertTrue(lockField.waitForExistence(timeout: timeout))
        captureScreen("landscape-03-lock-screen")
        XCTAssertTrue(lockField.isHittable, "the lock screen password field must be reachable in landscape")

        lockField.tap()
        lockField.typeText(masterPassword + "\n")
        XCTAssertTrue(
            app.navigationBars["SafeKey"].waitForExistence(timeout: timeout),
            "unlocking must work in landscape"
        )
        captureScreen("landscape-04-wallet-list")
    }
}
