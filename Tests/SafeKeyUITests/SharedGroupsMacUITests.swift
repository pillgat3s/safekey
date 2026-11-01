import XCTest

/// Shared groups on the Mac: the sidebar button, the creation sheet, the
/// Shared Groups section, and deleting from the group's Manage sheet. Runs
/// against the demo vault, whose iCloud is an in-process stand-in.
@MainActor
final class SharedGroupsMacUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func demoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SAFEKEY_DEMO"] = "1"
        app.launchEnvironment["SAFEKEY_WINDOW_FRAME"] = "1"
        return app
    }

    func testCreatingManagingAndDeletingASharedGroup() throws {
        let app = demoApp()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 10))

        // Create.
        let newShared = app.buttons["New Shared Group"]
        XCTAssertTrue(newShared.waitForExistence(timeout: 5), "the sidebar should offer a new shared group")
        newShared.click()
        XCTAssertTrue(app.staticTexts["New Shared Group"].waitForExistence(timeout: 5))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("Ops Team")
        app.buttons["Create"].click()
        XCTAssertTrue(app.buttons["Add People…"].waitForExistence(timeout: 10), "creating should offer inviting people")
        app.buttons["Done"].click()

        // Listed in its own section.
        XCTAssertTrue(app.staticTexts["Shared Groups"].waitForExistence(timeout: 5))
        let row = app.staticTexts["Ops Team"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Move a wallet in from its context menu, then look at the group.
        app.staticTexts["Daily Burner"].rightClick()
        let moveMenu = app.menuItems["Move to Group"]
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 5))
        moveMenu.hover()
        let target = app.menuItems["Ops Team"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "the shared group should be a move target")
        target.click()
        row.click()
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 5), "the wallet should be in the group")

        // Manage, then delete.
        row.rightClick()
        let manage = app.menuItems["Manage…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.click()
        XCTAssertTrue(app.staticTexts["Members"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Owner"].waitForExistence(timeout: 5))
        app.buttons["Delete Group…"].click()
        let confirm = app.buttons["Delete Group"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertFalse(app.staticTexts["Shared Groups"].waitForExistence(timeout: 3), "no section without a shared group")
        // The wallet is back among the vault's own.
        app.staticTexts["All"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 5), "deleting a shared group must keep the owner's wallets")
        app.terminate()
    }
}
