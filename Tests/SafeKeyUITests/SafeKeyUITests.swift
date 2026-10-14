import XCTest

/// UI smoke tests + screenshot capture. Screenshots land in the directory
/// given by TEST_RUNNER_SAFEKEY_SNAP_DIR (pass via xcodebuild), falling back
/// to attachments only.
@MainActor
final class SafeKeyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var snapDir: URL? {
        // xcodebuild passes runner env as TEST_RUNNER_-prefixed.
        let env = ProcessInfo.processInfo.environment
        let path = env["SAFEKEY_SNAP_DIR"] ?? env["TEST_RUNNER_SAFEKEY_SNAP_DIR"]
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func demoApp(state: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SAFEKEY_DEMO"] = "1"
        app.launchEnvironment["SAFEKEY_WINDOW_FRAME"] = "1"
        if let state {
            app.launchEnvironment["SAFEKEY_DEMO_STATE"] = state
        }
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        if let snapDir {
            try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: snapDir.appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMainWindowShowsDemoEntries() throws {
        let app = demoApp()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Sidebar tiles + demo entries present.
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Seed Phrases"].exists)
        XCTAssertTrue(app.staticTexts["Private Keys"].exists)

        // Select an entry → detail shows masked secret, not the words.
        app.staticTexts["Daily Burner"].click()
        XCTAssertTrue(app.staticTexts["Seed Phrase"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["bridge"].exists, "secret must be masked by default")

        sleep(2) // let the deterministic frame + glass settle
        snap(app, "main-ui")

        // Reveal the secret so the seed-phrase grid is captured too.
        if app.buttons["Reveal secret"].exists {
            app.buttons["Reveal secret"].click()
            sleep(1)
            snap(app, "detail-revealed")
        }
        app.terminate()
    }

    func testAddEntrySheet() throws {
        let app = demoApp()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 10))

        app.buttons["Add Wallet"].click()
        XCTAssertTrue(app.staticTexts["New Wallet"].waitForExistence(timeout: 5))
        sleep(1)
        snap(app, "add-sheet")
        app.terminate()
    }

    func testSettingsWindow() throws {
        let app = demoApp()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        // Settings opens on General; capture Security (the interesting one).
        if app.buttons["Security"].exists {
            app.buttons["Security"].click()
            sleep(1)
        }
        let settingsWindow = app.windows.element(boundBy: app.windows.count - 1)
        let screenshot = settingsWindow.screenshot()
        if let snapDir {
            try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: snapDir.appendingPathComponent("settings-security.png"))
        }
        app.terminate()
    }

    func testLockedStateAndUnlock() throws {
        let app = demoApp(state: "locked")
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["SafeKey Locked"].waitForExistence(timeout: 10))

        sleep(2)
        snap(app, "unlock-screen")

        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("demo-password-123\r")

        XCTAssertTrue(app.staticTexts["Daily Burner"].waitForExistence(timeout: 15), "vault should unlock into main UI")
        app.terminate()
    }

    func testWrongPasswordShowsError() throws {
        let app = demoApp(state: "locked")
        app.launch()
        XCTAssertTrue(app.staticTexts["SafeKey Locked"].waitForExistence(timeout: 10))

        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("definitely-wrong\r")

        XCTAssertTrue(app.staticTexts["Wrong password."].waitForExistence(timeout: 15))
        app.terminate()
    }
}
