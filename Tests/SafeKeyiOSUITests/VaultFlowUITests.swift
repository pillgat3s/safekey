import XCTest

/// End-to-end coverage of the flows a user actually performs. These drive the
/// real app against a scratch vault (`--uitest`), so they exercise the same
/// crypto, Keychain, and persistence paths as a shipping build.
final class VaultFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Long enough for PBKDF2 (calibrated to ~250 ms) plus animation.
    private let timeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    private func launch(reset: Bool = true) {
        app.launchArguments = reset ? ["--uitest", "--uitest-reset"] : ["--uitest"]
        app.launch()
    }

    private let masterPassword = "Correct-Horse-9"

    /// Onboarding → unlocked, empty vault.
    private func createVault(file: StaticString = #filePath, line: UInt = #line) {
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout), "onboarding never appeared", file: file, line: line)
        password.tap()
        password.typeText(masterPassword)

        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText(masterPassword)

        app.buttons["Create Vault"].tap()
        XCTAssertTrue(
            app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout),
            "vault creation did not land on the empty list",
            file: file, line: line
        )
    }

    /// Fills the add-wallet sheet and saves.
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

        app.buttons["Save"].tap()
    }

    private func lock() {
        app.buttons["Lock"].tap()
        XCTAssertTrue(lockPasswordField.waitForExistence(timeout: timeout))
    }

    private var lockPasswordField: XCUIElement { app.secureTextFields["lock.password"] }

    // MARK: - Tests

    func testCreateVaultLandsOnEmptyList() {
        launch()
        createVault()
        XCTAssertTrue(app.navigationBars["All Wallets"].exists)
    }

    func testCreateVaultRejectsMismatchedConfirmation() {
        launch()
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout))
        password.tap()
        password.typeText(masterPassword)

        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText("something-else")

        XCTAssertTrue(app.staticTexts["Passwords don't match"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create Vault"].isEnabled, "Create must stay disabled while the two differ")
    }

    func testAddedEntryAppearsInList() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xabc123def456")

        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["No Wallets Yet"].exists)
    }

    func testSecretIsMaskedUntilRevealed() {
        launch()
        createVault()
        let secret = "0xdeadbeefcafe1234"
        addEntry(name: "Main Wallet", secret: secret)

        app.staticTexts["Main Wallet"].tap()
        XCTAssertTrue(app.navigationBars["Main Wallet"].waitForExistence(timeout: timeout))

        XCTAssertFalse(app.staticTexts[secret].exists, "the secret must not render before Reveal")
        app.buttons["Reveal"].tap()
        XCTAssertTrue(app.staticTexts[secret].waitForExistence(timeout: timeout), "Reveal did not show the secret")

        app.buttons["Hide"].tap()
        XCTAssertFalse(app.staticTexts[secret].exists, "Hide did not re-mask the secret")
    }

    /// The core promise: data survives a lock, and only the right password opens it.
    func testEntrySurvivesLockAndUnlock() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xabc123def456")
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))

        lock()

        lockPasswordField.tap()
        lockPasswordField.typeText(masterPassword + "\n")

        XCTAssertTrue(
            app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout),
            "unlocking did not restore the entry"
        )
    }

    func testWrongPasswordIsRejected() {
        launch()
        createVault()
        lock()

        lockPasswordField.tap()
        lockPasswordField.typeText("not-the-password\n")

        XCTAssertTrue(
            app.staticTexts["Wrong password."].waitForExistence(timeout: timeout),
            "a wrong password must say so"
        )
        XCTAssertFalse(app.navigationBars["All Wallets"].exists, "a wrong password must not open the vault")
    }

    /// A relaunch is the real persistence test: it reloads the container from disk.
    func testVaultPersistsAcrossRelaunch() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xabc123def456")
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))

        app.terminate()
        launch(reset: false)

        XCTAssertTrue(
            lockPasswordField.waitForExistence(timeout: timeout),
            "a relaunch must come up locked, not onboarding"
        )
        lockPasswordField.tap()
        lockPasswordField.typeText(masterPassword + "\n")

        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
    }

    func testSearchFiltersTheList() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xaaa111")
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
        addEntry(name: "Cold Storage", secret: "0xbbb222")
        XCTAssertTrue(app.staticTexts["Cold Storage"].waitForExistence(timeout: timeout))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: timeout))
        search.tap()
        search.typeText("Cold")

        XCTAssertTrue(app.staticTexts["Cold Storage"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["Main Wallet"].exists, "search must hide non-matching entries")
    }

    func testSettingsOpens() {
        launch()
        createVault()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout))
    }
}
