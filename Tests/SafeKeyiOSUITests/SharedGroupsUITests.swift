import XCTest

/// Shared groups, as the user meets them: the + menu, the New Shared Group
/// steps, the Shared Groups section on the home screen, a group's own list
/// with its Manage button, and deleting the group without losing a wallet.
///
/// Runs against the in-process iCloud (`--uitest-fakecloud`), which owns
/// every group it makes. Inviting another account needs the real thing and
/// is covered by the coordinator tests instead.
final class SharedGroupsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 25
    private let masterPassword = "Correct-Horse-9"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-reset", "--uitest-fakecloud"]
    }

    override func tearDown() {
        // Left running on purpose when a test name says so, so the screens
        // can be looked at afterwards.
        if !name.contains("Stage") { app?.terminate() }
        super.tearDown()
    }

    // MARK: - Getting to a vault with wallets

    private func dismissWelcome() {
        let cont = app.buttons["welcome.continue"]
        if cont.waitForExistence(timeout: 15) { cont.tap() }
        let acknowledge = app.buttons["scope.acknowledge"]
        if acknowledge.waitForExistence(timeout: 10) { acknowledge.tap() }
    }

    private func declineBiometricOffer() {
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
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
        let landed = app.staticTexts["No Wallets Yet"].waitForExistence(timeout: timeout)
            || app.staticTexts["Nothing Here"].waitForExistence(timeout: timeout)
        XCTAssertTrue(landed, "vault creation did not land on an empty vault")
        declineBiometricOffer()
        try XCTSkipUnless(
            app.buttons["tile.All"].waitForExistence(timeout: 3),
            "the flow is checked on the iPhone tile home; the iPad sidebar lists groups its own way"
        )
    }

    private func addWallet(name: String) {
        app.tapAddWallet()
        XCTAssertTrue(app.navigationBars["New Wallet"].waitForExistence(timeout: timeout))
        let nameField = app.textFields["entry.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        nameField.tap()
        nameField.typeText(name + "\n")
        app.buttons["Private Key"].tap()
        let editor = app.textViews["entry.secret"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        focusEditor(editor)
        editor.typeText("0xabc123")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["SafeKey"].waitForExistence(timeout: timeout))
    }

    private func focusEditor(_ editor: XCUIElement) {
        for _ in 0..<4 {
            editor.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
            if (editor.value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    private func sharedGroupRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "home.sharedGroup.\(name)").firstMatch
    }

    private func backToHome() {
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: - The flow

    /// Creates "Ops Team" from the + menu and moves one of two wallets into
    /// it through the steps the sheet offers.
    private func createSharedGroup(named name: String, moving wallet: String) {
        app.buttons["home.add"].tap()
        let item = app.buttons["New Shared Group"]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "the + menu should offer a new shared group")
        captureScreen("shared-add-menu")
        item.tap()

        XCTAssertTrue(app.navigationBars["New Shared Group"].waitForExistence(timeout: timeout))
        let field = app.textFields["sharedGroup.name"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText(name)
        captureScreen("shared-new-name")
        app.buttons["sharedGroup.create"].tap()

        // Add People: the invitation needs iCloud, so the step is passed over.
        XCTAssertTrue(app.navigationBars["Add People"].waitForExistence(timeout: timeout), "creating should lead to adding people")
        XCTAssertTrue(app.buttons["sharedGroup.addPeople"].exists)
        captureScreen("shared-add-people")
        app.buttons["sharedGroup.next"].tap()

        XCTAssertTrue(app.navigationBars["Move Wallets"].waitForExistence(timeout: timeout))
        let move = app.buttons["sharedGroup.move"]
        XCTAssertFalse(move.isEnabled, "nothing is selected yet")
        let row = app.staticTexts[wallet]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.tap()
        XCTAssertTrue(move.isEnabled)
        captureScreen("shared-move-wallets")
        move.tap()

        XCTAssertTrue(sharedGroupRow(name).waitForExistence(timeout: timeout), "the group should be on the home screen")
    }

    func testCreatingASharedGroupMovesWalletsInAndListsItOnHome() throws {
        try createVault()
        addWallet(name: "Team hot wallet")
        addWallet(name: "Mine")
        createSharedGroup(named: "Ops Team", moving: "Team hot wallet")

        XCTAssertTrue(app.staticTexts["Shared Groups"].exists, "the section the Passwords app shows")
        XCTAssertTrue(app.staticTexts["My Wallets"].exists)
        XCTAssertTrue(app.staticTexts["Owner"].exists)
        captureScreen("shared-home")

        // The group's own list: one wallet, and a Manage button.
        sharedGroupRow("Ops Team").tap()
        XCTAssertTrue(app.staticTexts["Team hot wallet"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["Mine"].exists, "only what was moved in")
        XCTAssertTrue(app.staticTexts["1 Item"].exists)
        XCTAssertTrue(app.buttons["group.manage"].exists, "a shared group is managed from its list")
        captureScreen("shared-group-list")

        // My Wallets holds the rest.
        backToHome()
        app.descendants(matching: .any).matching(identifier: "home.myWallets").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Mine"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["Team hot wallet"].exists, "a shared wallet is not one of my own any more")
        backToHome()
    }

    func testManagingRenamesAndDeletingKeepsTheWallet() throws {
        try createVault()
        addWallet(name: "Team hot wallet")
        createSharedGroup(named: "Ops Team", moving: "Team hot wallet")

        sharedGroupRow("Ops Team").tap()
        XCTAssertTrue(app.buttons["group.manage"].waitForExistence(timeout: timeout))
        app.buttons["group.manage"].tap()
        XCTAssertTrue(app.navigationBars["Manage Group"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Members"].exists)
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Owner"].exists)
        captureScreen("shared-manage")

        // Rename from the manage screen.
        let rename = app.textFields["sharedGroup.rename"]
        rename.tap()
        let existing = (rename.value as? String) ?? ""
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        rename.typeText("Treasury\n")
        app.buttons["sharedGroup.done"].tap()
        // The list's title is its own view, not a navigation title, so it is
        // found as text.
        XCTAssertTrue(app.staticTexts["Treasury"].waitForExistence(timeout: timeout), "the list takes the new name")
        XCTAssertFalse(app.staticTexts["Ops Team"].exists, "the old name must be gone")

        // Delete, which keeps the wallet.
        app.buttons["group.manage"].tap()
        XCTAssertTrue(app.buttons["sharedGroup.delete"].waitForExistence(timeout: timeout))
        app.buttons["sharedGroup.delete"].tap()
        // The confirmation's button shares its label with the one that opened
        // it; the identifier tells them apart.
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'Delete Group' AND identifier != 'sharedGroup.delete'")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        captureScreen("shared-delete-confirm")
        confirm.tap()

        // Deleting the group from its own list leaves nothing to show there:
        // the app comes back to the home screen by itself.
        XCTAssertTrue(app.buttons["tile.All"].waitForExistence(timeout: timeout), "deleting the group should land back on the home screen")
        captureScreen("shared-home-after-delete")
        XCTAssertFalse(sharedGroupRow("Treasury").waitForExistence(timeout: 3), "the group should be gone")
        XCTAssertFalse(app.staticTexts["Shared Groups"].exists, "no section without a shared group")
        app.buttons["tile.All"].tap()
        XCTAssertTrue(app.staticTexts["Team hot wallet"].waitForExistence(timeout: timeout), "deleting a shared group must never delete the owner's wallets")
        XCTAssertTrue(app.staticTexts["EVM · Private Key"].exists, "back among my own wallets, ungrouped")
    }

    func testTheGroupPickerOffersSharedGroupsOnAWallet() throws {
        try createVault()
        addWallet(name: "Team hot wallet")
        addWallet(name: "Mine")
        createSharedGroup(named: "Ops Team", moving: "Team hot wallet")

        app.buttons["tile.All"].tap()
        XCTAssertTrue(app.staticTexts["Mine"].waitForExistence(timeout: timeout))
        app.staticTexts["Mine"].tap()
        let groupRow = app.buttons["detail.groupRow"]
        XCTAssertTrue(groupRow.waitForExistence(timeout: timeout))
        groupRow.tap()
        let option = app.buttons["Ops Team"]
        XCTAssertTrue(option.waitForExistence(timeout: timeout), "the shared group should be offered")
        captureScreen("shared-group-picker")
        option.tap()
        XCTAssertTrue(app.staticTexts["Ops Team"].waitForExistence(timeout: timeout), "the row shows the group")
        backToHome()
        backToHome()
        XCTAssertTrue(sharedGroupRow("Ops Team").waitForExistence(timeout: timeout))
    }

    /// Not a test of anything: leaves the app on the home screen with a
    /// shared group, for looking at.
    func testStageSharedGroupForInspection() throws {
        try createVault()
        addWallet(name: "Team hot wallet")
        addWallet(name: "Mine")
        createSharedGroup(named: "Ops Team", moving: "Team hot wallet")
    }
}
