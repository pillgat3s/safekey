#if os(iOS)
import XCTest
import SafeKeyCore
@testable import SafeKeyiOS

/// The recovery path, end to end through `AppModel`.
///
/// The UI tests cannot cover this: export and restore go through the system
/// document picker, which is another process. But this is the path that decides
/// whether a lost phone means lost keys, so the part that is ours — sealing the
/// container, rejecting rubbish, replacing the vault, and keeping a rescue copy
/// of what was there before — is worth testing directly.
@MainActor
final class BackupRoundTripiOSTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private let password = "Correct-Horse-9"

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeyBackupTests-\(UUID().uuidString)", isDirectory: true)
        let keychain = KeychainService(service: "com.andri.safekey.backuptest.\(UUID().uuidString)")
        model = AppModel(store: VaultStore(directory: directory), keychain: keychain)
    }

    override func tearDown() async throws {
        try? await model.store.destroy()
        try? model.keychain.deleteAll()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeVaultWithEntry(named name: String, secret: String) async throws {
        try await model.createVault(password: password)
        let session = try XCTUnwrap(model.session)
        session.upsert(WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: secret))
        await session.flushPendingSaves()
    }

    /// Export, wipe, restore: the wallets and their secrets come back.
    func testExportedBackupRestoresEveryEntry() async throws {
        try await makeVaultWithEntry(named: "Cold Storage", secret: "0xdeadbeef")
        let backup = try model.exportVaultData()

        // A backup is a sealed container — it must not carry the secret in clear.
        XCTAssertFalse(
            String(decoding: backup, as: UTF8.self).contains("0xdeadbeef"),
            "the exported backup contained the plaintext secret"
        )

        try await model.importVault(backup)
        guard case .locked = model.state else {
            return XCTFail("restoring should leave the vault locked, awaiting its own password")
        }

        try await model.unlock(password: password)
        let restored = try XCTUnwrap(model.session)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries.first?.name, "Cold Storage")
        XCTAssertEqual(restored.entries.first?.secret, "0xdeadbeef")
    }

    /// Restoring keeps a copy of the vault it replaced, so a backup that turns
    /// out to be the wrong one does not cost the user their working vault.
    func testRestoreKeepsARescueCopyOfTheReplacedVault() async throws {
        try await makeVaultWithEntry(named: "Original", secret: "0xaaa")
        let original = try await model.store.read()

        // A second, unrelated vault to restore over the top.
        let (otherContainer, _) = try Vault.create(password: "different-password-9")
        try await model.importVault(otherContainer)

        let rescue = await model.store.rescueCopy()
        XCTAssertEqual(rescue, original, "the replaced vault was not preserved")
    }

    /// Anything that is not a container must be refused before it can overwrite
    /// a working vault.
    func testGarbageIsRejectedBeforeItCanReplaceTheVault() async throws {
        try await makeVaultWithEntry(named: "Original", secret: "0xaaa")
        let before = try await model.store.read()

        XCTAssertThrowsError(try model.inspectBackup(Data("not a vault".utf8)))
        do {
            try await model.importVault(Data("not a vault".utf8))
            XCTFail("importing rubbish should throw")
        } catch {
            // expected
        }

        let after = try await model.store.read()
        XCTAssertEqual(after, before, "a rejected import must leave the vault untouched")
    }

    /// A backup opens with the password it had when it was saved — changing the
    /// password afterwards does not reach back into copies already exported.
    func testOldBackupStillOpensWithItsOriginalPassword() async throws {
        try await makeVaultWithEntry(named: "Cold Storage", secret: "0xdeadbeef")
        let backup = try model.exportVaultData()

        try await model.changePassword(old: password, new: "a-brand-new-password-9")

        try await model.importVault(backup)
        do {
            try await model.unlock(password: "a-brand-new-password-9")
            XCTFail("the new password must not open a backup taken before the change")
        } catch {
            // expected
        }
        try await model.unlock(password: password)
        XCTAssertEqual(model.session?.entries.first?.secret, "0xdeadbeef")
    }
}
#endif
