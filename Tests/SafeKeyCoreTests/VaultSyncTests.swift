import XCTest
import CryptoKit
@testable import SafeKeyCore

/// An in-memory stand-in for CloudKit, so the merge rules can be tested
/// without an Apple ID, a container, or a network.
actor FakeBackend: SyncBackend {
    private var records: [String: SyncRecord] = [:]
    private var deleted: [String] = []
    /// id → the version already delivered. Keyed by modification date, not by
    /// id alone: a record that changes must be handed back again, which is
    /// what a real store does.
    private var handedOut: [String: Date] = [:]

    private var vault: SyncedVault?

    func seed(_ record: SyncRecord) { records[record.id] = record }
    func remove(_ id: String) {
        records.removeValue(forKey: id)
        deleted.append(id)
    }
    var stored: [SyncRecord] { Array(records.values) }

    func fetchChanges(since token: Data?) async throws -> SyncChanges {
        // Hands back everything not yet delivered to this caller, which is
        // enough to model an incremental feed.
        let fresh = records.values.filter { handedOut[$0.id] != $0.modifiedAt }
        for record in fresh { handedOut[record.id] = record.modifiedAt }
        let deletions = deleted
        deleted = []
        return SyncChanges(records: Array(fresh), deletedIDs: deletions, token: Data([1]))
    }

    func save(_ incoming: [SyncRecord]) async throws {
        for record in incoming {
            records[record.id] = record
            handedOut[record.id] = record.modifiedAt
        }
    }

    func delete(ids: [String]) async throws {
        for id in ids { records.removeValue(forKey: id) }
    }

    func fetchVault() async throws -> SyncedVault? { vault }
    func saveVault(_ vault: SyncedVault) async throws { self.vault = vault }

    /// Forgets what has been handed out, modelling a second device that has
    /// never fetched from this zone before.
    func resetDeliveryLog() { handedOut = [:] }
}

final class VaultSyncTests: XCTestCase {
    private let dek = SymmetricKey(size: .bits256)

    private func entry(_ name: String, secret: String = "0xabc", modified: Date = .vaultNow()) -> WalletEntry {
        var entry = WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: secret)
        entry.modifiedAt = modified
        return entry
    }

    /// A wallet added here reaches the server sealed, not in clear.
    func testPushSealsTheEntry() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)
        var payload = VaultPayload(entries: [entry("Cold Storage", secret: "0xdeadbeef")])
        var state = VaultSync.State()

        let outcome = try await sync.run(payload: &payload, state: &state)

        XCTAssertEqual(outcome.pushed, 1)
        let stored = await backend.stored
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(
            String(decoding: stored[0].payload, as: UTF8.self).contains("0xdeadbeef"),
            "the secret must not travel in clear"
        )
    }

    /// A record sealed for one wallet must not open under another's id.
    func testRecordCannotBeMovedOntoAnotherWallet() throws {
        let original = entry("Real")
        let payload = try VaultSync.seal(original, dek: dek)
        XCTAssertThrowsError(
            try VaultSync.open(payload, id: UUID().uuidString, dek: dek),
            "a record re-labelled with a different id must fail to open"
        )
    }

    /// A wallet added on the other device arrives here.
    func testPullsRemoteAddition() async throws {
        let backend = FakeBackend()
        let remote = entry("From Phone")
        await backend.seed(SyncRecord(
            id: remote.id.uuidString,
            payload: try VaultSync.seal(remote, dek: dek),
            modifiedAt: remote.modifiedAt
        ))

        var payload = VaultPayload(entries: [])
        var state = VaultSync.State()
        let outcome = try await VaultSync(backend: backend, dek: dek).run(payload: &payload, state: &state)

        XCTAssertEqual(outcome.pulled, 1)
        XCTAssertEqual(payload.entries.first?.name, "From Phone")
    }

    /// Untouched here, newer there: the remote version wins cleanly.
    func testRemoteEditWinsWhenLocalUnchanged() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)
        var payload = VaultPayload(entries: [entry("Wallet", secret: "old")])
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        var edited = payload.entries[0]
        edited.secret = "new"
        edited.modifiedAt = Date().addingTimeInterval(60)
        await backend.seed(SyncRecord(
            id: edited.id.uuidString,
            payload: try VaultSync.seal(edited, dek: dek),
            modifiedAt: edited.modifiedAt
        ))

        let outcome = try await sync.run(payload: &payload, state: &state)
        XCTAssertEqual(outcome.pulled, 1)
        XCTAssertEqual(payload.entries.count, 1)
        XCTAssertEqual(payload.entries[0].secret, "new")
    }

    /// Edited in both places: neither side is thrown away.
    func testConflictKeepsBothVersions() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)
        var payload = VaultPayload(entries: [entry("Wallet", secret: "base")])
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        // The other device edits it…
        var theirs = payload.entries[0]
        theirs.secret = "theirs"
        theirs.modifiedAt = Date().addingTimeInterval(30)
        await backend.seed(SyncRecord(
            id: theirs.id.uuidString,
            payload: try VaultSync.seal(theirs, dek: dek),
            modifiedAt: theirs.modifiedAt
        ))
        // …and so do we, later.
        payload.entries[0].secret = "ours"
        payload.entries[0].modifiedAt = Date().addingTimeInterval(90)

        let outcome = try await sync.run(payload: &payload, state: &state)

        XCTAssertEqual(outcome.conflicts, 1)
        XCTAssertEqual(payload.entries.count, 2, "a clash must not cost a wallet")
        XCTAssertTrue(payload.entries.contains { $0.secret == "ours" })
        let incoming = payload.entries.first { $0.secret == "theirs" }
        XCTAssertNotNil(incoming, "the other device's version must be kept")
        XCTAssertTrue(incoming?.name.contains("conflicted copy") == true)
    }

    /// A wallet deleted on the other device does not come back.
    func testRemoteDeletionRemovesItLocally() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)
        var payload = VaultPayload(entries: [entry("Doomed")])
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        await backend.remove(payload.entries[0].id.uuidString)
        let outcome = try await sync.run(payload: &payload, state: &state)

        XCTAssertEqual(outcome.deletedLocally, 1)
        XCTAssertTrue(payload.entries.isEmpty)
    }

    /// Syncing twice with nothing changed must not re-push or duplicate.
    func testSecondRunIsQuiet() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)
        var payload = VaultPayload(entries: [entry("A"), entry("B")])
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        let second = try await sync.run(payload: &payload, state: &state)
        XCTAssertEqual(second, VaultSync.Outcome(), "an unchanged vault should be a no-op")
        XCTAssertEqual(payload.entries.count, 2, "syncing twice must not duplicate wallets")
    }

    /// A record from a different vault cannot be opened, and is left alone
    /// rather than deleted — another device may hold the key for it.
    func testForeignRecordIsSkippedNotDestroyed() async throws {
        let backend = FakeBackend()
        let foreign = entry("Someone else's")
        await backend.seed(SyncRecord(
            id: foreign.id.uuidString,
            payload: try VaultSync.seal(foreign, dek: SymmetricKey(size: .bits256)),
            modifiedAt: foreign.modifiedAt
        ))

        var payload = VaultPayload(entries: [])
        var state = VaultSync.State()
        let outcome = try await VaultSync(backend: backend, dek: dek).run(payload: &payload, state: &state)

        XCTAssertEqual(outcome.pulled, 0)
        XCTAssertTrue(payload.entries.isEmpty)
        let stored = await backend.stored
        XCTAssertEqual(stored.count, 1, "an unreadable record must be left where it is")
    }
}

/// Joining a second device with only the master password.
///
/// This is the path that makes sync behave the way iCloud is expected to: turn
/// it on elsewhere, type the master password, and the wallets arrive. It works
/// because the vault header — salt, KDF parameters and the wrapped data key —
/// travels alongside the wallets. Without the header a device that knows the
/// password still has nothing to derive from.
final class VaultAdoptionTests: XCTestCase {
    private let password = "Correct-Horse-9"

    /// Puts a vault and its wallets into the backend the way a first device
    /// would, and returns what that device holds.
    private func publishVault(
        to backend: FakeBackend,
        wallets: [String]
    ) async throws -> Vault.Unlocked {
        let (container, unlocked) = try Vault.create(password: password, iterations: 1_000)
        _ = container
        var seeded = unlocked
        for name in wallets {
            seeded.payload.entries.append(
                WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: "0x\(name)")
            )
        }
        let engine = VaultSync(backend: backend, dek: seeded.dek)
        try await engine.publishVault(header: seeded.header)
        var payload = seeded.payload
        var state = VaultSync.State()
        _ = try await engine.run(payload: &payload, state: &state)
        return seeded
    }

    func testSecondDeviceJoinsWithTheMasterPassword() async throws {
        let backend = FakeBackend()
        let original = try await publishVault(to: backend, wallets: ["Cold Storage", "Hot Wallet"])
        await backend.resetDeliveryLog()

        let (adopted, state) = try await VaultSync.adoptRemoteVault(backend: backend, password: password)

        XCTAssertEqual(adopted.header.vaultID, original.header.vaultID, "it must be the same vault")
        XCTAssertEqual(Set(adopted.payload.entries.map(\.name)), ["Cold Storage", "Hot Wallet"])
        XCTAssertEqual(
            adopted.dek.withUnsafeBytes { Data($0) },
            original.dek.withUnsafeBytes { Data($0) },
            "the joining device must derive the same data key"
        )
        XCTAssertEqual(state.agreed.count, 2, "joining should leave the bookkeeping already caught up")
    }

    func testWrongPasswordCannotJoin() async throws {
        let backend = FakeBackend()
        _ = try await publishVault(to: backend, wallets: ["Cold Storage"])
        await backend.resetDeliveryLog()

        do {
            _ = try await VaultSync.adoptRemoteVault(backend: backend, password: "not-the-password")
            XCTFail("a wrong password must not open the vault")
        } catch {
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
    }

    /// Nothing published yet is a clear refusal, not an empty vault that would
    /// look like the wallets had vanished.
    func testJoiningAnEmptyCloudRefuses() async throws {
        let backend = FakeBackend()
        do {
            _ = try await VaultSync.adoptRemoteVault(backend: backend, password: password)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SyncError, .unavailable("There is no vault in iCloud yet."))
        }
    }

    /// After joining, an immediate sync must be quiet: the wallets just pulled
    /// down must not be pushed back as if they were new.
    func testSyncAfterJoiningIsQuiet() async throws {
        let backend = FakeBackend()
        _ = try await publishVault(to: backend, wallets: ["Cold Storage", "Hot Wallet"])
        await backend.resetDeliveryLog()

        var (adopted, state) = try await VaultSync.adoptRemoteVault(backend: backend, password: password)
        var payload = adopted.payload
        let outcome = try await VaultSync(backend: backend, dek: adopted.dek)
            .run(payload: &payload, state: &state)

        XCTAssertEqual(outcome, VaultSync.Outcome(), "joining then syncing should change nothing")
        XCTAssertEqual(payload.entries.count, 2, "joining must not duplicate the wallets")
    }

    /// A wallet added on the joined device reaches the other one.
    func testEditsFlowBackAfterJoining() async throws {
        let backend = FakeBackend()
        let original = try await publishVault(to: backend, wallets: ["Cold Storage"])
        await backend.resetDeliveryLog()

        var (adopted, state) = try await VaultSync.adoptRemoteVault(backend: backend, password: password)
        var payload = adopted.payload
        payload.entries.append(WalletEntry(name: "Added On Phone", chain: .solana, kind: .privateKey, secret: "0xnew"))
        _ = try await VaultSync(backend: backend, dek: adopted.dek).run(payload: &payload, state: &state)

        // Now the first device syncs and should see it.
        await backend.resetDeliveryLog()
        var firstPayload = original.payload
        var firstState = VaultSync.State()
        let outcome = try await VaultSync(backend: backend, dek: original.dek)
            .run(payload: &firstPayload, state: &firstState)

        XCTAssertTrue(
            firstPayload.entries.contains { $0.name == "Added On Phone" },
            "a wallet added on the joined device must reach the other one"
        )
        XCTAssertGreaterThan(outcome.pulled, 0)
    }
}

/// Merging two vaults that each hold wallets the other does not.
///
/// Both sides are decrypted in memory on a device that has legitimately opened
/// both, so nothing is revealed that it did not already hold. Afterwards there
/// is one vault, opened by the surviving vault's password.
final class VaultMergeTests: XCTestCase {
    private let localPassword = "Local-Horse-9"
    private let remotePassword = "Remote-Horse-9"

    private func makeVault(password: String, wallets: [String]) throws -> Vault.Unlocked {
        let (_, unlocked) = try Vault.create(password: password, iterations: 1_000)
        var seeded = unlocked
        for name in wallets {
            seeded.payload.entries.append(
                WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: "secret-\(name)")
            )
        }
        return seeded
    }

    private func publish(_ vault: Vault.Unlocked, to backend: FakeBackend) async throws {
        let engine = VaultSync(backend: backend, dek: vault.dek)
        try await engine.publishVault(header: vault.header)
        var payload = vault.payload
        var state = VaultSync.State()
        _ = try await engine.run(payload: &payload, state: &state)
        await backend.resetDeliveryLog()
    }

    /// The point of the feature: neither side loses a wallet.
    func testMergeKeepsWalletsFromBothVaults() async throws {
        let backend = FakeBackend()
        let remote = try makeVault(password: remotePassword, wallets: ["On Phone A", "On Phone B"])
        try await publish(remote, to: backend)
        let local = try makeVault(password: localPassword, wallets: ["On Mac"])

        let (merged, adopted) = try await VaultSync.mergeRemoteVault(
            backend: backend, password: remotePassword, into: local
        )

        XCTAssertEqual(adopted, 2)
        XCTAssertEqual(Set(merged.payload.entries.map(\.name)), ["On Mac", "On Phone A", "On Phone B"])
    }

    /// The absorbed wallets are readable under the surviving vault's key, not
    /// the one they arrived under.
    func testAbsorbedWalletsOpenUnderTheSurvivingKey() async throws {
        let backend = FakeBackend()
        let remote = try makeVault(password: remotePassword, wallets: ["On Phone"])
        try await publish(remote, to: backend)
        let local = try makeVault(password: localPassword, wallets: ["On Mac"])

        let (merged, _) = try await VaultSync.mergeRemoteVault(
            backend: backend, password: remotePassword, into: local
        )

        XCTAssertEqual(merged.header.vaultID, local.header.vaultID, "the local vault survives")
        // Sealing and reopening under the surviving key proves the merged set
        // is genuinely usable, not just assembled in memory.
        let container = try Vault.seal(merged)
        let reopened = try Vault.unlock(container: container, password: localPassword)
        XCTAssertEqual(Set(reopened.payload.entries.map(\.name)), ["On Mac", "On Phone"])
        XCTAssertEqual(
            reopened.payload.entries.first { $0.name == "On Phone" }?.secret,
            "secret-On Phone",
            "an absorbed secret must survive intact"
        )
    }

    func testMergeNeedsTheOtherVaultsPassword() async throws {
        let backend = FakeBackend()
        try await publish(try makeVault(password: remotePassword, wallets: ["On Phone"]), to: backend)
        let local = try makeVault(password: localPassword, wallets: ["On Mac"])

        do {
            _ = try await VaultSync.mergeRemoteVault(backend: backend, password: "wrong", into: local)
            XCTFail("merging must require the other vault's password")
        } catch {
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
    }

    /// A wallet already here is not duplicated by a merge.
    func testMergeDoesNotDuplicateSharedWallets() async throws {
        let backend = FakeBackend()
        let shared = WalletEntry(name: "Shared", chain: .evm, kind: .privateKey, secret: "0xsame")
        var remote = try makeVault(password: remotePassword, wallets: [])
        remote.payload.entries = [shared]
        try await publish(remote, to: backend)

        var local = try makeVault(password: localPassword, wallets: ["On Mac"])
        local.payload.entries.append(shared)

        let (merged, adopted) = try await VaultSync.mergeRemoteVault(
            backend: backend, password: remotePassword, into: local
        )

        XCTAssertEqual(adopted, 0)
        XCTAssertEqual(merged.payload.entries.filter { $0.name == "Shared" }.count, 1)
    }

    /// An absorbed wallet keeps its group, because the group travels with it.
    func testMergeBringsGroupsAcross() async throws {
        let backend = FakeBackend()
        var remote = try makeVault(password: remotePassword, wallets: [])
        let group = WalletGroup(name: "Cold Storage", chain: .evm)
        var entry = WalletEntry(name: "Grouped", chain: .evm, kind: .privateKey, secret: "0x1")
        entry.groupID = group.id
        remote.payload.groups = [group]
        remote.payload.entries = [entry]
        try await publish(remote, to: backend)
        let local = try makeVault(password: localPassword, wallets: ["On Mac"])

        let (merged, _) = try await VaultSync.mergeRemoteVault(
            backend: backend, password: remotePassword, into: local
        )

        XCTAssertTrue(merged.payload.groups.contains { $0.name == "Cold Storage" })
        XCTAssertEqual(
            merged.payload.entries.first { $0.name == "Grouped" }?.groupID,
            group.id,
            "an absorbed wallet should keep the group it belonged to"
        )
    }

    /// A wallet pointing at a group that genuinely did not come across is left
    /// plainly ungrouped, never holding an id that is not in the file.
    func testWalletWithMissingGroupIsUngrouped() async throws {
        let backend = FakeBackend()
        var remote = try makeVault(password: remotePassword, wallets: [])
        var entry = WalletEntry(name: "Orphan", chain: .evm, kind: .privateKey, secret: "0x1")
        entry.groupID = UUID()   // a group that exists nowhere
        remote.payload.entries = [entry]
        try await publish(remote, to: backend)
        let local = try makeVault(password: localPassword, wallets: ["On Mac"])

        let (merged, _) = try await VaultSync.mergeRemoteVault(
            backend: backend, password: remotePassword, into: local
        )

        XCTAssertNil(merged.payload.entries.first { $0.name == "Orphan" }?.groupID)
    }
}

/// Groups travel between devices the same way wallets do.
final class GroupSyncTests: XCTestCase {
    private let dek = SymmetricKey(size: .bits256)

    func testGroupReachesTheOtherDevice() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)

        var payload = VaultPayload()
        payload.groups = [WalletGroup(name: "Cold Storage", chain: .solana, icon: "❄️")]
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        // A second device starting from nothing.
        await backend.resetDeliveryLog()
        var other = VaultPayload()
        var otherState = VaultSync.State()
        _ = try await sync.run(payload: &other, state: &otherState)

        XCTAssertEqual(other.groups.count, 1)
        XCTAssertEqual(other.groups.first?.name, "Cold Storage")
        XCTAssertEqual(other.groups.first?.icon, "❄️", "the chosen icon should travel too")
    }

    func testRenamedGroupWinsWhenNewer() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)
        var payload = VaultPayload()
        payload.groups = [WalletGroup(name: "Old Name", chain: .evm)]
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        var renamed = payload.groups[0]
        renamed.name = "New Name"
        renamed.modifiedAt = Date().addingTimeInterval(60)
        await backend.seed(SyncRecord(
            id: VaultSync.groupPrefix + renamed.id.uuidString,
            payload: try VaultSync.seal(renamed, dek: dek),
            modifiedAt: renamed.modifiedAt
        ))

        _ = try await sync.run(payload: &payload, state: &state)
        XCTAssertEqual(payload.groups.first?.name, "New Name")
        XCTAssertEqual(payload.groups.count, 1, "a rename must not become a second group")
    }

    /// Deleting a group elsewhere must not take its wallets with it.
    func testDeletedGroupUngroupsRatherThanDeletingWallets() async throws {
        let backend = FakeBackend()
        let sync = VaultSync(backend: backend, dek: dek)

        let group = WalletGroup(name: "Doomed", chain: .evm)
        var entry = WalletEntry(name: "Keeper", chain: .evm, kind: .privateKey, secret: "0x1")
        entry.groupID = group.id
        var payload = VaultPayload()
        payload.groups = [group]
        payload.entries = [entry]
        var state = VaultSync.State()
        _ = try await sync.run(payload: &payload, state: &state)

        await backend.remove(VaultSync.groupPrefix + group.id.uuidString)
        _ = try await sync.run(payload: &payload, state: &state)

        XCTAssertTrue(payload.groups.isEmpty)
        XCTAssertEqual(payload.entries.count, 1, "the wallet must survive its group")
        XCTAssertNil(payload.entries.first?.groupID)
    }
}
