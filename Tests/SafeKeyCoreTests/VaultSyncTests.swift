import XCTest
import CryptoKit
@testable import SafeKeyCore

/// An in-memory stand-in for CloudKit, so the merge rules can be tested
/// without an Apple ID, a container, or a network.
private actor FakeBackend: SyncBackend {
    private var records: [String: SyncRecord] = [:]
    private var deleted: [String] = []
    /// id → the version already delivered. Keyed by modification date, not by
    /// id alone: a record that changes must be handed back again, which is
    /// what a real store does.
    private var handedOut: [String: Date] = [:]

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
