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

    func testTourEveryScreen() {
        app.launchArguments = ["--uitest", "--uitest-reset"]
        app.launch()

        // 1. Onboarding
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
        XCTAssertTrue(app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout))
        capture("03-empty-vault")

        // 2. Add a seed phrase and a private key
        addEntry(
            name: "Ledger Recovery",
            secret: "abandon ability able about above absent absorb abstract absurd abuse access accident",
            seedPhrase: true
        )
        XCTAssertTrue(app.staticTexts["Ledger Recovery"].waitForExistence(timeout: timeout))
        addEntry(name: "Hot Wallet", secret: "0x4c0883a69102937d6231471b5dbb6204fe512961708279fe6f39a1c9a3f0dd4e")
        XCTAssertTrue(app.staticTexts["Hot Wallet"].waitForExistence(timeout: timeout))
        capture("04-wallet-list")

        // 3. Detail, masked then revealed
        app.staticTexts["Ledger Recovery"].tap()
        XCTAssertTrue(app.navigationBars["Ledger Recovery"].waitForExistence(timeout: timeout))
        capture("05-detail-masked")
        app.buttons["Reveal"].tap()
        XCTAssertTrue(app.staticTexts["abandon"].waitForExistence(timeout: timeout))
        capture("06-detail-revealed")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 4. Settings
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: timeout))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout))
        capture("07-settings-top")
        app.swipeUp()
        capture("08-settings-bottom")
        app.buttons["Done"].tap()

        // 5. Lock screen
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: timeout))
        app.buttons["Lock"].tap()
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
