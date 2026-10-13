import XCTest

/// Walks the app and saves a PNG of each screen so the UI can be reviewed
/// without a human driving the simulator.
///
/// Screenshots land in the test runner's own container, which the host can
/// locate with:
///   xcrun simctl get_app_container <udid> com.andri.safekey.uitests.ios.xctrunner data
final class ScreenshotTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 20
    private let masterPassword = "Correct-Horse-9"

    private var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SafeKeyShots", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    /// First run opens on the welcome screen now.
    private func dismissWelcome() {
        let cont = app.buttons["welcome.continue"]
        if cont.waitForExistence(timeout: 15) { cont.tap() }
        // Then the notice of what SafeKey is for, which must be acknowledged.
        let acknowledge = app.buttons["scope.acknowledge"]
        if acknowledge.waitForExistence(timeout: 10) { acknowledge.tap() }
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

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        // Attached for the .xcresult bundle, and written to disk for quick review.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    func testTourEveryScreen() throws {
        app.launchArguments = ["--uitest", "--uitest-reset"]
        app.launch()

        // 1. Welcome, then onboarding
        XCTAssertTrue(app.buttons["welcome.continue"].waitForExistence(timeout: timeout))
        capture("00-welcome")
        dismissWelcome()
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout))
        capture("01-onboarding-empty")

        password.tap()
        password.typeText(masterPassword)
        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText(masterPassword)
        capture("02-onboarding-filled")

        app.buttons["Create Vault"].tap()
        // The iPhone lands on the tile home; an iPad lands on the split view,
        // whose preselected All list shows its own empty state.
        let landed = app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout)
            || app.staticTexts["Nothing Here"].waitForExistence(timeout: timeout)
        XCTAssertTrue(landed, "vault creation did not land on an empty vault")
        declineBiometricOffer()
        capture("03-empty-vault")

        // 2. Add a seed phrase and a private key
        // 24 words and a long name: the grid and the title have to cope with
        // the largest thing a user can realistically store.
        addEntry(
            name: "Ledger Nano X — Long Term Cold Storage",
            secret: "abandon ability able about above absent absorb abstract absurd abuse access accident "
                + "account accuse achieve acid acoustic acquire across act action actor actress actual",
            seedPhrase: true
        )
        addEntry(name: "Hot Wallet", secret: "0x4c0883a69102937d6231471b5dbb6204fe512961708279fe6f39a1c9a3f0dd4e")
        capture("04-home-with-wallets")

        // 3. The list one level down
        // The tour walks the iPhone tile home; the iPad split view has its
        // own layout and is covered by the flow tests.
        try XCTSkipUnless(
            app.buttons["tile.All"].waitForExistence(timeout: 5),
            "tile home not present — iPad layout"
        )
        let tile = app.buttons["tile.All"]
        XCTAssertTrue(tile.waitForExistence(timeout: timeout))
        tile.tap()
        XCTAssertTrue(app.staticTexts["Hot Wallet"].waitForExistence(timeout: timeout))
        capture("04b-wallet-list")

        // 4. Detail, masked then revealed
        app.staticTexts["Ledger Nano X — Long Term Cold Storage"].tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        capture("05-detail-masked")
        secretRow.tap()
        XCTAssertTrue(app.staticTexts["abandon"].waitForExistence(timeout: timeout))
        capture("06-detail-revealed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Hot Wallet"].waitForExistence(timeout: timeout))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 5. Settings
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: timeout))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout))
        capture("07-settings-top")
        app.swipeUp()
        capture("08-settings-bottom")

        app.swipeDown()
        if app.buttons["Groups"].waitForExistence(timeout: 5) {
            app.buttons["Groups"].tap()
            XCTAssertTrue(app.navigationBars["Groups"].waitForExistence(timeout: timeout))
            capture("08a-groups")
            // Scope to this screen's bar by title: on iPad the settings sheet is
            // a form sheet, so the list's navigation bar is on screen too and an
            // unscoped query can pick a button out of the wrong one.
            app.navigationBars["Groups"].buttons.firstMatch.tap()
        }
        if app.buttons["Change Master Password"].waitForExistence(timeout: 5) {
            app.buttons["Change Master Password"].tap()
            XCTAssertTrue(app.navigationBars["Master Password"].waitForExistence(timeout: timeout))
            capture("08b-change-password")
            app.navigationBars["Master Password"].buttons.firstMatch.tap()
        }

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: timeout))
        app.buttons["Done"].tap()

        // 6. Lock screen
        // The vault locks by leaving the foreground; there is no manual lock.
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 15)
        app.activate()
        XCTAssertTrue(app.secureTextFields["lock.password"].waitForExistence(timeout: timeout))
        capture("09-lock-screen")
    }

    private func addEntry(name: String, secret: String, seedPhrase: Bool = false) {
        app.buttons["Add Wallet"].tap()
        XCTAssertTrue(app.navigationBars["New Wallet"].waitForExistence(timeout: timeout))

        let nameField = app.textFields["entry.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        nameField.tap()
        nameField.typeText(name)

        app.buttons[seedPhrase ? "Seed Phrase" : "Private Key"].tap()

        let editor = app.textViews["entry.secret"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText(secret)

        if seedPhrase { capture("04a-new-wallet-sheet") }
        app.buttons["Save"].tap()
    }
}
