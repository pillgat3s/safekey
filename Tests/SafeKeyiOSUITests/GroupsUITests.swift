import XCTest

/// Groups: create from the bottom bar, assign while editing a wallet, then
/// rename and delete by long-pressing the group on the home screen.
///
/// The delete case matters most — a group is a folder, and tidying a folder
/// away must never take the wallets with it.
final class GroupsUITests: XCTestCase {
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
        app?.terminate()
        super.tearDown()
    }

    private func createVault() throws {
        app.launch()
        dismissWelcome()
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout))
        password.tap()
        password.typeText(masterPassword)
        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText(masterPassword)
        app.buttons["Create Vault"].tap()
        // The iPhone lands on the tile home; an iPad lands on the split view,
        // whose preselected All list shows its own empty state.
        let landed = app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout)
            || app.staticTexts["Nothing Here"].waitForExistence(timeout: timeout)
        XCTAssertTrue(landed, "vault creation did not land on an empty vault")
        declineBiometricOffer()
        try XCTSkipUnless(
            app.buttons["tile.All"].waitForExistence(timeout: 3),
            "group rows live on the iPhone tile home; the iPad sidebar lists groups its own way"
        )
    }

    /// Creates a group from the bottom bar, the way the app offers it.
    private func createGroup(named name: String) {
        app.buttons["New Group"].tap()
        XCTAssertTrue(app.navigationBars["New Group"].waitForExistence(timeout: timeout))
        let field = app.textFields["group.name"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText(name)
        app.buttons["Create"].tap()
        XCTAssertTrue(groupRow(name).waitForExistence(timeout: timeout), "the new group should appear on the home screen")
    }

    /// Assigns a group from the wallet's own screen — the menu on the Group
    /// row — which is how the app offers it.
    private func assignGroup(_ group: String, toWalletNamed name: String) {
        openAll()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: timeout))
        app.staticTexts[name].tap()

        let groupRow = app.buttons["detail.groupRow"]
        XCTAssertTrue(groupRow.waitForExistence(timeout: timeout), "no group row on the wallet screen")
        groupRow.tap()

        let option = app.buttons[group]
        XCTAssertTrue(option.waitForExistence(timeout: timeout), "group \(group) was not offered")
        option.tap()

        // Back to the list, then home.
        app.navigationBars.buttons.firstMatch.tap()
        backToHome()
    }

    private func addWallet(name: String) {
        app.buttons["Add Wallet"].tap()
        XCTAssertTrue(app.navigationBars["New Wallet"].waitForExistence(timeout: timeout))

        let nameField = app.textFields["entry.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        nameField.tap()
        nameField.typeText(name)

        app.buttons["Private Key"].tap()
        let editor = app.textViews["entry.secret"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText("0xabc123")

        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["SafeKey"].waitForExistence(timeout: timeout))
    }

    private func groupRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "home.group.\(name)")
            .firstMatch
    }

    private func openAll() {
        let tile = app.buttons["tile.All"]
        XCTAssertTrue(tile.waitForExistence(timeout: timeout))
        tile.tap()
    }

    private func backToHome() {
        app.navigationBars.buttons.firstMatch.tap()
    }

    func testCreatedGroupIsListedOnHome() throws {
        try createVault()
        createGroup(named: "Day Trading")
        XCTAssertTrue(app.staticTexts["Day Trading"].waitForExistence(timeout: timeout))
    }

    func testRenamingAGroupUpdatesTheWalletRow() throws {
        try createVault()
        createGroup(named: "Day Trading")
        addWallet(name: "Trading")
        assignGroup("Day Trading", toWalletNamed: "Trading")

        groupRow("Day Trading").press(forDuration: 1.2)
        app.buttons["Rename"].tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        // Clear the prefilled name first: typing appends, and an alert's text
        // field has no clear button to press.
        field.tap()
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText("Long Term")
        app.alerts.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Long Term"].waitForExistence(timeout: timeout))
        openAll()
        XCTAssertTrue(
            app.staticTexts["EVM · Private Key · Long Term"].waitForExistence(timeout: timeout),
            "renaming a group should be reflected wherever it is shown"
        )
        backToHome()
    }

    /// Deleting a group must keep its wallets.
    func testDeletingAGroupKeepsItsWallets() throws {
        try createVault()
        createGroup(named: "Day Trading")
        addWallet(name: "Trading")
        assignGroup("Day Trading", toWalletNamed: "Trading")

        groupRow("Day Trading").press(forDuration: 1.2)
        app.buttons["Delete Group"].tap()
        app.buttons["Delete"].tap()

        XCTAssertFalse(
            app.staticTexts["Day Trading"].waitForExistence(timeout: 5),
            "the group should be gone"
        )

        openAll()
        XCTAssertTrue(
            app.staticTexts["Trading"].waitForExistence(timeout: timeout),
            "deleting a group must never delete the wallets inside it"
        )
        XCTAssertTrue(app.staticTexts["EVM · Private Key"].exists, "the wallet should simply be ungrouped now")
    }
}
