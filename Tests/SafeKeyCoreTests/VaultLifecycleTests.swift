import XCTest
import CryptoKit
@testable import SafeKeyCore

/// End-to-end lifecycle through the real store: the exact sequence the app
/// performs across launches.
final class VaultLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLifecycle-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testCreateAddQuitReopenEditReopen() async throws {
        let password = "a-real-master-password"

        // Launch 1: create the vault and add an entry.
        do {
            let store = VaultStore(directory: tempDir)
            let (container, unlocked) = try Vault.create(password: password, iterations: testIterations)
            try await store.write(container)

            var session = unlocked
            session.payload.entries.append(
                WalletEntry(
                    name: "Main ETH",
                    chain: .evm,
                    kind: .seedPhrase(wordCount: 12),
                    secret: "abandon ability able about above absent absorb abstract absurd abuse access accident"
                )
            )
            try await store.write(try Vault.seal(session))
        }

        // Launch 2: unlock with the password, verify data, edit settings.
        do {
            let store = VaultStore(directory: tempDir)
            let exists = await store.vaultExists()
            XCTAssertTrue(exists)
            let container = try await store.read()
            var session = try Vault.unlock(container: container, password: password)
            XCTAssertEqual(session.payload.entries.count, 1)
            XCTAssertEqual(session.payload.entries[0].name, "Main ETH")

            session.payload.settings.autoLockSeconds = 60
            session.header.selfDestruct = SelfDestructPolicy(enabled: true, maxAttempts: 4)
            try await store.write(try Vault.seal(session))
        }

        // Launch 3: policy + settings survived; wrong password still rejected.
        do {
            let store = VaultStore(directory: tempDir)
            let container = try await store.read()
            XCTAssertThrowsError(try Vault.unlock(container: container, password: "wrong")) {
                XCTAssertEqual($0 as? VaultError, .wrongPassword)
            }
            let session = try Vault.unlock(container: container, password: password)
            XCTAssertEqual(session.payload.settings.autoLockSeconds, 60)
            XCTAssertTrue(session.header.selfDestruct.enabled)
            XCTAssertEqual(session.header.selfDestruct.maxAttempts, 4)
        }
    }

    func testFullTwoFactorLifecycle() async throws {
        let password = "master-password-2fa"
        let store = VaultStore(directory: tempDir)
        let (container, unlocked) = try Vault.create(password: password, iterations: testIterations)
        try await store.write(container)

        // Enable the USB factor.
        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let policy = UnlockPolicy(requiresDevice: true, volumeUUID: "UUID", volumeName: "KEY", keyFileRelPath: VolumeDeviceKeyProvider.defaultKeyRelPath)
        let twoFactor = try DeviceKeyFactor.apply(
            to: unlocked, password: password,
            currentDeviceKey: nil, newPolicy: policy, newDeviceKey: deviceKey
        )
        try await store.write(try Vault.seal(twoFactor))

        // Password alone fails; password + key works.
        let reloaded = try await store.read()
        XCTAssertThrowsError(try Vault.unlock(container: reloaded, password: password)) {
            XCTAssertEqual($0 as? VaultError, .deviceKeyRequired)
        }
        _ = try Vault.unlock(container: reloaded, password: password, deviceKey: deviceKey)

        // Change the password while two-factor is on.
        let changed = try Vault.changePassword(
            container: reloaded, oldPassword: password,
            newPassword: "new-master-password", deviceKey: deviceKey
        )
        try await store.write(changed)

        let afterChange = try await store.read()
        XCTAssertThrowsError(try Vault.unlock(container: afterChange, password: password, deviceKey: deviceKey)) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
        let final = try Vault.unlock(container: afterChange, password: "new-master-password", deviceKey: deviceKey)
        XCTAssertTrue(final.header.unlockPolicy.requiresDevice)

        // A password change re-wraps the same DEK (so the biometric copy stays
        // valid)...
        XCTAssertEqual(
            final.dek.withUnsafeBytes { Data($0) },
            twoFactor.dek.withUnsafeBytes { Data($0) }
        )
        // ...but enabling the device factor ROTATED it, so the original DEK —
        // recoverable from any pre-2FA backup with the old password — is dead.
        XCTAssertNotEqual(
            final.dek.withUnsafeBytes { Data($0) },
            unlocked.dek.withUnsafeBytes { Data($0) }
        )
    }
}
