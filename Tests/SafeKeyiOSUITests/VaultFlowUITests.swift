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

    /// First run opens on the welcome screen now.
    private func dismissWelcome() {
        let cont = app.buttons["welcome.continue"]
        if cont.waitForExistence(timeout: 15) { cont.tap() }
        // Then the notice of what SafeKey is for, which must be acknowledged.
        let acknowledge = app.buttons["scope.acknowledge"]
        if acknowledge.waitForExistence(timeout: 10) { acknowledge.tap() }
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

    // MARK: - Helpers

    private func launch(reset: Bool = true) {
        app.launchArguments = reset ? ["--uitest", "--uitest-reset"] : ["--uitest"]
        app.launch()
    }

    private let masterPassword = "Correct-Horse-9"

    /// Onboarding → unlocked, empty vault.
    private func createVault(file: StaticString = #filePath, line: UInt = #line) {
        dismissWelcome()
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout), "onboarding never appeared", file: file, line: line)
        type(masterPassword, into: password)

        let confirm = app.secureTextFields["onboarding.confirm"]
        type(masterPassword, into: confirm)

        app.buttons["Create Vault"].tap()
        // The iPhone lands on the tile home; an iPad lands on the split view,
        // whose preselected All list shows its own empty state.
        let landed = app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout)
            || app.staticTexts["Nothing Here"].waitForExistence(timeout: timeout)
        if !landed { captureScreen("landing-debug") }
        XCTAssertTrue(landed, "vault creation did not land on an empty vault", file: file, line: line)
        declineBiometricOffer()
    }

    /// Fills the add-wallet sheet and saves.
    private func addEntry(name: String, secret: String, seedPhrase: Bool = false) {
        app.buttons["Add Wallet"].tap()
        XCTAssertTrue(app.navigationBars["New Wallet"].waitForExistence(timeout: timeout))

        let nameField = app.textFields["entry.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        type(name, into: nameField)

        app.buttons[seedPhrase ? "Seed Phrase" : "Private Key"].tap()

        let editor = app.textViews["entry.secret"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        editor.typeText(secret)

        app.buttons["Save"].tap()
    }

    /// Wallets live one level below the home screen now: open the "All" tile.
    /// Taps the field, waits for the keyboard to actually connect, and only
    /// then types. On an iPad, `typeText` straight after `tap()` races the
    /// keyboard attach and silently drops leading characters — which in a
    /// password field looks like nothing at all until the mismatch error.
    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        field.typeText(text)
    }

    private func openAll() {
        // iPhone: the All tile on the home grid. iPad: the split view already
        // shows the All list — its sidebar row exists, the tile does not.
        let tile = app.buttons["tile.All"]
        if tile.waitForExistence(timeout: 3) {
            tile.tap()
        } else {
            // The list titles itself with a principal toolbar view, so the
            // nav bar carries no name — the "All" text itself is the probe.
            XCTAssertTrue(
                app.staticTexts["All"].waitForExistence(timeout: timeout),
                "neither the All tile nor the All list is on screen"
            )
        }
    }

    private func lock() {
        lockVault()
        XCTAssertTrue(lockPasswordField.waitForExistence(timeout: timeout))
    }

    private var lockPasswordField: XCUIElement { app.secureTextFields["lock.password"] }

    // MARK: - Tests

    /// Between the welcome and the password there is a notice of what SafeKey
    /// is for, and nothing goes forward — not creating a vault, not restoring
    /// one — until it has been acknowledged.
    func testScopeNoticeMustBeAcknowledged() {
        launch()
        let cont = app.buttons["welcome.continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: timeout))
        cont.tap()

        let acknowledge = app.buttons["scope.acknowledge"]
        XCTAssertTrue(acknowledge.waitForExistence(timeout: timeout), "the scope notice did not appear")
        XCTAssertTrue(app.staticTexts["Made for Burner Wallets"].exists)
        XCTAssertFalse(app.secureTextFields["onboarding.password"].exists, "the password step must wait for the acknowledgement")
        XCTAssertFalse(app.buttons["Restore from a Backup…"].exists, "restoring must wait for the acknowledgement too")

        acknowledge.tap()
        XCTAssertTrue(app.secureTextFields["onboarding.password"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["Restore from a Backup…"].exists)
    }

    func testCreateVaultLandsOnEmptyList() {
        launch()
        createVault()
        XCTAssertTrue(app.navigationBars["SafeKey"].exists)
    }

    func testCreateVaultRejectsMismatchedConfirmation() {
        launch()
        dismissWelcome()
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

        XCTAssertFalse(app.staticTexts["No Wallets Yet"].exists)
        openAll()
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
    }

    func testSecretIsMaskedUntilRevealed() {
        launch()
        createVault()
        let secret = "0xdeadbeefcafe1234"
        addEntry(name: "Main Wallet", secret: secret)

        openAll()
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
        app.staticTexts["Main Wallet"].tap()

        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        captureScreen("reveal-1-masked")

        let revealed = app.staticTexts["detail.secret"]
        XCTAssertFalse(revealed.exists, "the secret must not render before Reveal")

        // The row reveals in place on a tap and hides on the next, the way
        // the Passwords app treats a password. Copy lives on a long press.
        secretRow.tap()
        XCTAssertTrue(revealed.waitForExistence(timeout: timeout), "tapping the row did not reveal the secret")
        captureScreen("reveal-2-revealed")
        XCTAssertEqual(revealed.label, secret, "the row revealed something other than the stored secret")

        secretRow.tap()
        XCTAssertFalse(
            app.staticTexts["detail.secret"].waitForExistence(timeout: 3),
            "tapping again did not re-mask the secret"
        )
    }

    /// Revealing a seed phrase shows every word, numbered, first to last. The
    /// grid sits inside the screenshot-proof host, so this is also the check
    /// that the host lays its content out in full.
    func testRevealingASeedPhraseShowsEveryWord() {
        launch()
        createVault()
        addEntry(name: "Paper Backup",
                 secret: "orbit velvet canyon harbor timber silent garden pilot crystal bridge echo fabric",
                 seedPhrase: true)

        openAll()
        XCTAssertTrue(app.staticTexts["Paper Backup"].waitForExistence(timeout: timeout))
        app.staticTexts["Paper Backup"].tap()
        let secretRow = app.buttons["detail.secretRow"]
        XCTAssertTrue(secretRow.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["velvet"].exists, "the words must not render before Reveal")

        secretRow.tap()
        XCTAssertTrue(app.staticTexts["orbit"].waitForExistence(timeout: timeout), "the first word is missing")
        XCTAssertTrue(app.staticTexts["fabric"].exists, "the last word is missing")
        XCTAssertTrue(app.staticTexts["12"].exists, "the words should be numbered")
    }

    /// Locking is not a reset. The vault relocks whenever the app leaves the
    /// foreground, and coming back should land on the wallet that was open —
    /// the way a credential vault does — rather than on the home grid.
    func testUnlockingReturnsToTheWalletThatWasOpen() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xabc123")

        openAll()
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
        app.staticTexts["Main Wallet"].tap()
        XCTAssertTrue(app.buttons["detail.secretRow"].waitForExistence(timeout: timeout))

        lock()
        type(masterPassword + "\n", into: lockPasswordField)

        XCTAssertTrue(
            app.buttons["detail.secretRow"].waitForExistence(timeout: timeout),
            "unlocking should return to the wallet that was open"
        )
        XCTAssertFalse(app.buttons["tile.All"].exists, "the home grid must not be what comes back")
        XCTAssertFalse(
            app.staticTexts["detail.secret"].exists,
            "the secret must come back hidden, whatever it was before the lock"
        )

        // And the stack underneath is intact: back leads to the list, not home.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["All"].waitForExistence(timeout: timeout))
    }

    /// The core promise: data survives a lock, and only the right password opens it.
    func testEntrySurvivesLockAndUnlock() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xabc123def456")

        lock()

        lockPasswordField.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        lockPasswordField.typeText(masterPassword + "\n")

        openAll()
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
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        lockPasswordField.typeText("not-the-password\n")

        XCTAssertTrue(
            app.staticTexts["Wrong password."].waitForExistence(timeout: timeout),
            "a wrong password must say so"
        )
        XCTAssertFalse(app.navigationBars["SafeKey"].exists, "a wrong password must not open the vault")
    }

    /// A relaunch is the real persistence test: it reloads the container from disk.
    func testVaultPersistsAcrossRelaunch() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xabc123def456")

        app.terminate()
        launch(reset: false)

        XCTAssertTrue(
            lockPasswordField.waitForExistence(timeout: timeout),
            "a relaunch must come up locked, not onboarding"
        )
        lockPasswordField.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        lockPasswordField.typeText(masterPassword + "\n")

        openAll()
        XCTAssertTrue(app.staticTexts["Main Wallet"].waitForExistence(timeout: timeout))
    }

    /// Search lives on the home screen and shows results in place.
    func testSearchFiltersTheList() {
        launch()
        createVault()
        addEntry(name: "Main Wallet", secret: "0xaaa111")
        addEntry(name: "Cold Storage", secret: "0xbbb222")

        // The system search field in the bottom bar; it carries no
        // identifier of ours, and it is the only search field on the home
        // screen.
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
