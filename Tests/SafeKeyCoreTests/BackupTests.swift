import XCTest
import CryptoKit
@testable import SafeKeyCore

/// A backup is the exact encrypted container the app persists, so "export" is
/// `Vault.seal` and "import" is writing bytes back. These tests pin the
/// properties that keep that safe: a backup opens only with its own password,
/// survives a full round trip, a wrong password still fails, and a file that is
/// not a real container is rejected before anything is written.
final class BackupTests: XCTestCase {
    private let password = "correct horse battery staple"

    func testBackupRoundTripOpensWithItsPassword() throws {
        let payload = makeTestPayload()
        let (_, unlocked) = try Vault.create(password: password, payload: payload, iterations: testIterations)

        // Export == seal the live session.
        let backup = try Vault.seal(unlocked)

        // A backup is a valid container.
        let header = try VaultFileFormat.decode(backup).header
        XCTAssertEqual(header.vaultID, unlocked.header.vaultID)

        // Import == treat those bytes as the vault and unlock with the password.
        let restored = try Vault.unlock(container: backup, password: password)
        XCTAssertEqual(restored.payload, payload)
    }

    func testBackupStillRejectsWrongPassword() throws {
        let (_, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        let backup = try Vault.seal(unlocked)
        XCTAssertThrowsError(try Vault.unlock(container: backup, password: "not it")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testBackupPreservesTwoFactorRequirement() throws {
        let (_, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let policy = UnlockPolicy(requiresDevice: true, keyFileRelPath: VolumeDeviceKeyProvider.defaultKeyRelPath)
        let twoFactor = try DeviceKeyFactor.apply(
            to: unlocked, password: password,
            currentDeviceKey: nil, newPolicy: policy, newDeviceKey: deviceKey
        )
        let backup = try Vault.seal(twoFactor)

        // The restored vault still needs the device key — the policy travels
        // with the container, so a backup cannot be a way to strip 2FA.
        XCTAssertThrowsError(try Vault.unlock(container: backup, password: password)) {
            XCTAssertEqual($0 as? VaultError, .deviceKeyRequired)
        }
        XCTAssertNoThrow(try Vault.unlock(container: backup, password: password, deviceKey: deviceKey))
    }

    func testNonContainerIsRejected() {
        for junk in [Data(), Data("not a vault".utf8), Data(repeating: 0xFF, count: 200)] {
            XCTAssertThrowsError(try VaultFileFormat.decode(junk),
                                 "import validation must reject \(junk.count) bytes of junk")
        }
    }

    /// Structural damage — a cut into the header — is rejected at import time
    /// by `decode`, before anything is written.
    func testHeaderDamageRejectedAtImport() throws {
        let (_, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        let backup = try Vault.seal(unlocked)
        // 14 bytes in is inside the header JSON; cut there.
        XCTAssertThrowsError(try VaultFileFormat.decode(backup.prefix(20)))
    }

    /// Payload corruption cannot be detected without the password — GCM needs
    /// the key — so `decode` accepts it structurally, and the damage surfaces
    /// as `.tampered` at unlock. This test pins that honest boundary so nobody
    /// later mistakes `inspectBackup` for a full integrity check.
    func testPayloadCorruptionSurfacesAtUnlockNotImport() throws {
        let (_, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        var backup = try Vault.seal(unlocked)
        backup[backup.count - 4] ^= 0x01   // flip a byte in the sealed payload

        // Import-time validation still passes: the header is intact.
        XCTAssertNoThrow(try VaultFileFormat.decode(backup))
        // But the correct password cannot open it — authentication fails.
        XCTAssertThrowsError(try Vault.unlock(container: backup, password: password)) {
            XCTAssertEqual($0 as? VaultError, .tampered)
        }
    }
}
