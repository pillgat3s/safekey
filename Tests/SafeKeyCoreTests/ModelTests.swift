import XCTest
@testable import SafeKeyCore

final class ModelTests: XCTestCase {
    func testWalletEntryCodableRoundTrip() throws {
        let entry = WalletEntry(
            name: "Main ETH",
            chain: .evm,
            kind: .seedPhrase(wordCount: 12),
            secret: "test test test test test test test test test test test junk",
            publicAddress: "0x0000000000000000000000000000000000000000",
            tags: ["hot"]
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WalletEntry.self, from: data)
        XCTAssertEqual(entry, decoded)
    }

    func testDebugDescriptionRedactsSecret() {
        let entry = WalletEntry(name: "X", chain: .bitcoin, kind: .privateKey, secret: "SUPERSECRET")
        XCTAssertFalse(String(reflecting: entry).contains("SUPERSECRET"))
    }

    /// A vault written before a setting existed must still open. Losing a vault
    /// because a new preference was added would be unforgivable.
    func testSettingsDecodeWithMissingKeys() throws {
        let json = "{\"autoLockSeconds\":300,\"lockOnSleep\":true,\"lockOnScreenLock\":true,"
            + "\"clipboardClearSeconds\":30,\"revealPolicy\":{\"never\":{}},"
            + "\"defaultChain\":\"evm\",\"sortOrder\":\"dateModified\"}"
        let settings = try VaultJSON.decoder().decode(VaultSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.cloudBackupEnabled, "new setting defaults off")
        XCTAssertEqual(settings.autoLockSeconds, 300)
    }

    /// Even a nearly empty settings object should decode to sane defaults.
    func testSettingsDecodeFromEmptyObject() throws {
        let settings = try VaultJSON.decoder().decode(VaultSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.autoLockSeconds, 300)
        XCTAssertFalse(settings.cloudBackupEnabled)
    }
}

/// The screen-capture toggle's contract: protection is the default, older
/// vaults keep it, and turning it off survives a round trip.
final class ScreenCaptureSettingTests: XCTestCase {
    func testProtectionIsTheDefault() {
        XCTAssertTrue(VaultSettings().effectiveBlockScreenCapture)
    }

    func testAVaultWrittenBeforeTheToggleKeepsProtection() throws {
        // A payload from a build that never heard of the key.
        let legacy = Data(#"{"lockOnSleep":true}"#.utf8)
        let decoded = try VaultJSON.decoder().decode(VaultSettings.self, from: legacy)
        XCTAssertNil(decoded.blockScreenCapture)
        XCTAssertTrue(decoded.effectiveBlockScreenCapture, "an old vault must not silently lose the protection")
    }

    func testTurningItOffRoundTrips() throws {
        var settings = VaultSettings()
        settings.blockScreenCapture = false
        let data = try VaultJSON.encoder().encode(settings)
        let decoded = try VaultJSON.decoder().decode(VaultSettings.self, from: data)
        XCTAssertFalse(decoded.effectiveBlockScreenCapture)
    }
}
