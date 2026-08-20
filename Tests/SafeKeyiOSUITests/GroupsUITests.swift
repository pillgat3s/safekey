import XCTest

/// Groups: create one while editing a wallet, filter by it, rename it, delete it.
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

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func createVault() {
        app.launch()
        let password = app.secureTextFields["onboarding.password"]
        XCTAssertTrue(password.waitForExistence(timeout: timeout))
        password.tap()
        password.typeText(masterPassword)
        let confirm = app.secureTextFields["onboarding.confirm"]
        confirm.tap()
        confirm.typeText(masterPassword)
        app.buttons["Create Vault"].tap()
        XCTAssertTrue(app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout))
    }

    /// Adds a wallet, creating `group` on the way when given.
    private func addWallet(name: String, group: String? = nil) {
        app.buttons["Add Wallet"].tap()
        XCTAssertTrue(app.navigationBars["New Wallet"].waitForExistence(timeout: timeout))

        let nameField = app.textFields["entry.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        nameField.tap()
        nameField.typeText(name)

        if let group {
            app.buttons["New Group…"].tap()
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: timeout))
            field.typeText(group)
            app.alerts.buttons["Create"].tap()
        }

        app.buttons["Private Key"].tap()
        let editor = app.textViews["entry.secret"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText("0xabc123")

        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: timeout))
    }

    private func openGroups() {
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout))
        app.buttons["Groups"].tap()
        XCTAssertTrue(app.navigationBars["Groups"].waitForExistence(timeout: timeout))
    }

    func testCreatingAGroupAssignsItAndListsIt() {
        createVault()
        addWallet(name: "Trading", group: "Day Trading")

        // The row subtitle carries the group, so assignment is visible at a glance.
        XCTAssertTrue(
            app.staticTexts["EVM · Private Key · Day Trading"].waitForExistence(timeout: timeout),
            "the wallet row should show which group it belongs to"
        )

        openGroups()
        XCTAssertTrue(app.staticTexts["Day Trading"].waitForExistence(timeout: timeout))
    }

    func testRenamingAGroupUpdatesTheWalletRow() {
        createVault()
        addWallet(name: "Trading", group: "Day Trading")
        openGroups()

        app.staticTexts["Day Trading"].tap()
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

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.staticTexts["EVM · Private Key · Long Term"].waitForExistence(timeout: timeout),
            "renaming a group should be reflected wherever it is shown"
        )
    }

    /// Deleting a group must keep its wallets.
    func testDeletingAGroupKeepsItsWallets() {
        createVault()
        addWallet(name: "Trading", group: "Day Trading")
        openGroups()

        let row = app.staticTexts["Day Trading"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete Group"].tap()

        XCTAssertTrue(
            app.staticTexts["No Groups"].waitForExistence(timeout: timeout),
            "the group should be gone"
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.staticTexts["Trading"].waitForExistence(timeout: timeout),
            "deleting a group must never delete the wallets inside it"
        )
        XCTAssertTrue(app.staticTexts["EVM · Private Key"].exists, "the wallet should simply be ungrouped now")
    }
}
