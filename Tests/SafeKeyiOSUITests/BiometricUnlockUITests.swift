import XCTest

/// Face ID enable → lock → unlock, end to end.
///
/// The simulator only completes a biometric evaluation when the *host* posts a
/// match, which a test running on the device cannot do for itself. Run
/// `scripts/simulator_faceid_match.sh <udid>` alongside this test; it posts
/// matches on a loop so whichever prompt is on screen succeeds.
///
/// Skipped automatically when biometrics are not enrolled, so an ordinary
/// `xcodebuild test` on a clean simulator does not fail for the wrong reason.
final class BiometricUnlockUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30
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

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testEnableFaceIDThenUnlockWithIt() throws {
        app.launchArguments = ["--uitest", "--uitest-reset"]
        app.launch()

        // Onboarding
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

        // Settings → enable biometric unlock
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout))

        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Unlock with'")).firstMatch
        try XCTSkipUnless(
            toggle.waitForExistence(timeout: 5),
            "no biometry enrolled on this simulator — enable it and rerun"
        )
        captureScreen("bio-01-before-toggle")
        // A SwiftUI Toggle in a Form reports the whole row as the switch, and
        // only the control at the trailing edge actually flips it — tapping the
        // element's centre lands on the label and does nothing at all.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        captureScreen("bio-02-after-toggle")

        // The enable prompt has to clear before the switch reports on.
        // XCTWaiter rather than `expectation(for:)`: the latter captures the
        // test case itself, which Swift 6 rejects as non-Sendable.
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '1'"),
            object: toggle
        )
        let result = XCTWaiter().wait(for: [enabled], timeout: timeout)
        captureScreen("bio-03-after-wait")
        XCTAssertEqual(
            result,
            .completed,
            "the biometric toggle never turned on — the enable prompt was not satisfied"
        )

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: timeout))

        // Relaunch rather than tapping Lock. A fresh launch with a vault on disk
        // always comes up locked, so reaching the wallet list from here — with
        // no password typed anywhere in this test — can only be biometrics.
        // (Tapping Lock proves less: the lock screen offers Face ID the moment
        // it appears, so it can come and go faster than an assertion can see.)
        app.terminate()
        app.launchArguments = ["--uitest"]
        app.launch()

        // The lock screen offers biometrics on appear; the button is the retry
        // for when that first offer was already answered.
        let retry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock with'")).firstMatch
        if retry.waitForExistence(timeout: 5) {
            retry.tap()
        }

        XCTAssertTrue(
            app.navigationBars["SafeKey"].waitForExistence(timeout: timeout),
            "biometric unlock did not open the vault"
        )
        captureScreen("bio-04-unlocked")
    }
}
