import XCTest

/// Self-destruct, driven through the real UI against a scratch vault.
///
/// Worth testing end to end rather than only in the core: arming is a settings
/// toggle behind a typed confirmation, and the counter is what the lock screen
/// reports. A bug anywhere in that chain either erases a vault that should have
/// survived, or fails to erase one that should not have.
final class SelfDestructUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 25
    private let masterPassword = "Correct-Horse-9"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// First run opens on the welcome screen now.
    private func dismissWelcome() {
        let cont = app.buttons["welcome.continue"]
        if cont.waitForExistence(timeout: 15) { cont.tap() }
    }

    /// Backgrounds the app and comes back, which is how the vault locks now
    /// that there is no manual lock button — so this exercises the real
    /// mechanism rather than a button that only existed for the tests.
    private func lockVault() {
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 15)
        app.activate()
        XCTAssertTrue(
            app.secureTextFields["lock.password"].waitForExistence(timeout: timeout),
            "leaving the foreground should have locked the vault"
        )
    }

    /// A freshly created vault now offers biometric unlock. Tests that are not
    /// about biometrics decline it, so the alert does not sit over the UI.
    private func declineBiometricOffer() {
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func createVault() {
        dismissWelcome()
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout))
        password.tap()
        password.typeText(masterPassword)
        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText(masterPassword)
        app.buttons["Create Vault"].tap()
        XCTAssertTrue(app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout))
        declineBiometricOffer()
    }

    /// Only the trailing control of a Form toggle actually flips it; tapping the
    /// element's centre lands on the label.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func arm(attempts: Int) {
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout))

        let toggle = app.switches["Erase after failed attempts"]
        XCTAssertTrue(toggle.waitForExistence(timeout: timeout))
        flip(toggle)

        // Typed confirmation — arming must never be a single tap.
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "arming did not ask for confirmation")
        field.typeText("DELETE")
        app.alerts.buttons["Arm"].tap()

        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: timeout), "attempt count is not adjustable once armed")
        // Default is 5; step down to the requested count.
        let decrement = stepper.buttons["Decrement"].exists
            ? stepper.buttons["Decrement"]
            : stepper.buttons.element(boundBy: 0)
        for _ in 0..<max(0, 5 - attempts) {
            decrement.tap()
        }

        app.buttons["Done"].tap()
    }

    private func attemptWrongPassword() {
        let field = app.secureTextFields["lock.password"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("definitely-not-it\n")
    }

    /// Typing DELETE is required, and a wrong password then costs an attempt
    /// that the lock screen reports back.
    func testArmingRequiresConfirmationAndCountsDown() {
        app.launchArguments = ["--uitest", "--uitest-reset"]
        app.launch()
        createVault()
        arm(attempts: 3)

        lockVault()
        attemptWrongPassword()

        XCTAssertTrue(
            app.staticTexts["Self-destruct armed: 2 attempts left."].waitForExistence(timeout: timeout),
            "the lock screen must report how many attempts remain"
        )
    }

    /// The real thing: exhaust the attempts and the vault is gone, leaving a
    /// first-run app rather than a lock screen.
    func testExhaustingAttemptsDestroysTheVault() {
        app.launchArguments = ["--uitest", "--uitest-reset"]
        app.launch()
        createVault()
        arm(attempts: 3)

        lockVault()
        for _ in 0..<3 {
            attemptWrongPassword()
        }

        // First run is the tell: no vault left to unlock. Dismissing the
        // welcome screen and finding the *create* fields — not the lock
        // screen — is what proves the vault is gone rather than merely locked.
        dismissWelcome()
        XCTAssertTrue(
            app.secureTextFields["onboarding.confirm"].waitForExistence(timeout: timeout),
            "the vault should have been erased and the app returned to first run"
        )

        // And it must stay gone across a relaunch — not merely be hidden.
        app.terminate()
        app.launchArguments = ["--uitest"]
        app.launch()
        dismissWelcome()
        XCTAssertTrue(
            app.secureTextFields["onboarding.confirm"].waitForExistence(timeout: timeout),
            "a destroyed vault came back after relaunch"
        )
    }

    /// The counter resets on success, so an unarmed-looking near-miss does not
    /// quietly carry over and erase the vault on some later day.
    func testCorrectPasswordResetsTheCounter() {
        app.launchArguments = ["--uitest", "--uitest-reset"]
        app.launch()
        createVault()
        arm(attempts: 3)

        lockVault()
        attemptWrongPassword()
        XCTAssertTrue(app.staticTexts["Self-destruct armed: 2 attempts left."].waitForExistence(timeout: timeout))

        let field = app.secureTextFields["lock.password"]
        field.tap()
        field.typeText(masterPassword + "\n")
        XCTAssertTrue(app.navigationBars["SafeKey"].waitForExistence(timeout: timeout))

        lockVault()
        attemptWrongPassword()
        XCTAssertTrue(
            app.staticTexts["Self-destruct armed: 2 attempts left."].waitForExistence(timeout: timeout),
            "a successful unlock must clear the failed-attempt count"
        )
    }
}
