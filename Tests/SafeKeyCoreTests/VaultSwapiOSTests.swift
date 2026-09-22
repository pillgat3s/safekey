#if os(iOS)
import XCTest
import SafeKeyCore
@testable import SafeKeyiOS

/// What happens to this device's Face ID enrolment, and to the screen you were
/// on, when the vault underneath changes.
///
/// The enrolment is keyed to a vault's ID. Restoring a different vault — or
/// adopting one from iCloud, which takes the same path through the model —
/// used to leave the newcomer without Face ID and say nothing, so the password
/// was asked for on every open until someone found the switch in Settings.
@MainActor
final class VaultSwapiOSTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private let password = "Correct-Horse-9"

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeySwapTests-\(UUID().uuidString)", isDirectory: true)
        let keychain = KeychainService(service: "com.andri.safekey.swaptest.\(UUID().uuidString)")
        model = AppModel(store: VaultStore(directory: directory), keychain: keychain)
    }

    override func tearDown() async throws {
        if let session = model.session {
            try? model.biometricFactor.disable(vaultID: session.header.vaultID)
        }
        if let header = model.lockedHeader {
            try? model.biometricFactor.disable(vaultID: header.vaultID)
        }
        try? await model.store.destroy()
        try? model.keychain.deleteAll()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A sealed container for a vault that is not this device's.
    private func foreignVault() throws -> Data {
        let (container, _) = try Vault.create(password: password)
        return container
    }

    // MARK: - The Face ID offer

    func testRestoringADifferentVaultQueuesTheBiometricOffer() async throws {
        try await model.createVault(password: password)
        model.clearBiometricOffer()

        try await model.importVault(try foreignVault())

        XCTAssertTrue(
            model.biometricOfferPending,
            "a vault that took this device's place should be offered Face ID once"
        )
        guard case .locked = model.state else { return XCTFail("a restored vault comes up locked") }
    }

    func testTheOfferClearsOnceTaken() async throws {
        try await model.createVault(password: password)
        try await model.importVault(try foreignVault())
        model.clearBiometricOffer()
        XCTAssertFalse(model.biometricOfferPending)
    }

    /// The outgoing vault's key must not stay in the Keychain: it is a copy of
    /// a data key behind Face ID for a vault that is no longer on the device.
    func testRestoringADifferentVaultDropsTheOldVaultsBiometricKey() async throws {
        try XCTSkipUnless(
            BiometricFactor.isBiometryAvailable(),
            "no biometry enrolled — enrol Face ID on this simulator to run this"
        )
        try await model.createVault(password: password)
        let outgoing = try XCTUnwrap(model.session).header.vaultID
        try await model.enableBiometricUnlock(confirm: false)
        XCTAssertTrue(model.biometricFactor.isEnrolled(vaultID: outgoing))

        try await model.importVault(try foreignVault())

        XCTAssertFalse(
            model.biometricFactor.isEnrolled(vaultID: outgoing),
            "the replaced vault's biometric key should have gone with it"
        )
        XCTAssertTrue(model.biometricOfferPending)
    }

    /// Restoring a backup of the *same* vault is not a swap: Face ID keeps
    /// working, and there is nothing to offer.
    func testRestoringTheSameVaultKeepsItsEnrolment() async throws {
        try XCTSkipUnless(
            BiometricFactor.isBiometryAvailable(),
            "no biometry enrolled — enrol Face ID on this simulator to run this"
        )
        try await model.createVault(password: password)
        let vaultID = try XCTUnwrap(model.session).header.vaultID
        try await model.enableBiometricUnlock(confirm: false)
        let backup = try model.exportVaultData()

        try await model.importVault(backup)

        XCTAssertTrue(model.biometricFactor.isEnrolled(vaultID: vaultID))
        XCTAssertFalse(model.biometricOfferPending, "nothing changed hands, so nothing to offer")
    }

    // MARK: - Coming back to the same screen

    func testResumePathKeepsOnlyStepsThatStillResolve() async throws {
        try await model.createVault(password: password)
        let session = try XCTUnwrap(model.session)
        let entry = WalletEntry(name: "Main", chain: .evm, kind: .privateKey, secret: "0xabc")
        session.upsert(entry)
        let group = session.addGroup(name: "Cold", chain: .evm, colorHex: nil)
        await session.flushPendingSaves()

        let intact: [HomeRoute] = [.list(.group(group.id)), .entry(entry.id)]
        XCTAssertEqual(intact.validated(in: session), intact)

        // The wallet went away while the app was locked: the list still
        // stands, the wallet does not.
        session.delete(id: entry.id)
        XCTAssertEqual(intact.validated(in: session), [.list(.group(group.id))])

        // The group went too: the path ends at the first stale step, and a
        // wallet step behind it cannot be reached without it.
        session.deleteGroup(id: group.id)
        let orphan = WalletEntry(name: "Other", chain: .evm, kind: .privateKey, secret: "0xdef")
        session.upsert(orphan)
        XCTAssertEqual(
            [HomeRoute.list(.group(group.id)), .entry(orphan.id)].validated(in: session),
            []
        )
        XCTAssertEqual([HomeRoute.list(.all), .entry(orphan.id)].validated(in: session),
                       [.list(.all), .entry(orphan.id)])
    }

    func testResumeStateDropsASelectionForAVanishedGroup() async throws {
        try await model.createVault(password: password)
        let session = try XCTUnwrap(model.session)
        let group = session.addGroup(name: "Cold", chain: .evm, colorHex: nil)
        var state = ResumeState()
        state.splitSelection = .group(group.id)
        XCTAssertEqual(state.validated(in: session).splitSelection, .group(group.id))

        session.deleteGroup(id: group.id)
        XCTAssertNil(state.validated(in: session).splitSelection)
    }
}
#endif
