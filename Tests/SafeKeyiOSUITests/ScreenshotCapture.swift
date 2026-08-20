import XCTest

extension XCTestCase {
    /// Saves a PNG of the current screen into the runner's container, where the
    /// host can read it:
    ///   xcrun simctl get_app_container <udid> com.andri.safekey.uitests.ios.xctrunner data
    func captureScreen(_ name: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeyShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
