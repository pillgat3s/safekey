import Foundation
import CryptoKit

/// Merges a vault against a remote store, one wallet at a time.
///
/// Per-wallet rather than whole-vault on purpose. The vault is a single sealed
/// blob, and two blobs cannot be merged — whoever wrote last would silently
/// erase the other device's work. Sealing each wallet separately means a clash
/// costs one wallet, and even then the loser is kept rather than discarded.
public struct VaultSync: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var pulled: Int
        public var pushed: Int
        public var deletedLocally: Int
        /// Wallets edited on both sides since the last sync. Both versions are
        /// kept — the incoming one is added alongside under a new id.
        public var conflicts: Int

        public init(pulled: Int = 0, pushed: Int = 0, deletedLocally: Int = 0, conflicts: Int = 0) {
            self.pulled = pulled
            self.pushed = pushed
            self.deletedLocally = deletedLocally
            self.conflicts = conflicts
        }
    }

    /// What a sync run needs to remember between runs, per vault.
    public struct State: Codable, Sendable, Equatable {
        public var token: Data?
        /// Wallet id → the modification date last agreed with the server, so a
        /// local edit since then can be told apart from an untouched wallet.
        public var syncedAt: [String: Date]

        public init(token: Data? = nil, syncedAt: [String: Date] = [:]) {
            self.token = token
            self.syncedAt = syncedAt
        }
    }

    private let backend: any SyncBackend
    private let dek: SymmetricKey

    public init(backend: any SyncBackend, dek: SymmetricKey) {
        self.backend = backend
        self.dek = dek
    }

    // MARK: - Sealing

    /// Each wallet sealed under the vault key, with its own id as additional
    /// authenticated data — so a record moved onto another wallet's id fails to
    /// open rather than silently impersonating it.
    static func seal(_ entry: WalletEntry, dek: SymmetricKey) throws -> Data {
        let plaintext = try VaultJSON.encoder().encode(entry)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: dek,
            authenticating: Data(entry.id.uuidString.utf8)
        )
        guard let combined = sealed.combined else { throw VaultError.cryptoFailure }
        return combined
    }

    static func open(_ payload: Data, id: String, dek: SymmetricKey) throws -> WalletEntry {
        let box = try AES.GCM.SealedBox(combined: payload)
        let plaintext = try AES.GCM.open(box, using: dek, authenticating: Data(id.utf8))
        return try VaultJSON.decoder().decode(WalletEntry.self, from: plaintext)
    }

    // MARK: - Merge

    /// Pulls remote changes into `payload`, then pushes whatever is newer here.
    public func run(payload: inout VaultPayload, state: inout State) async throws -> Outcome {
        var outcome = Outcome()
        let changes = try await backend.fetchChanges(since: state.token)

        for record in changes.records {
            guard let incoming = try? Self.open(record.payload, id: record.id, dek: dek) else {
                // A record we cannot open is not ours to interpret. Skipping it
                // is safer than deleting it: another device may hold the key.
                continue
            }
            if let index = payload.entries.firstIndex(where: { $0.id == incoming.id }) {
                let local = payload.entries[index]
                let lastAgreed = state.syncedAt[record.id]
                let localChanged = lastAgreed.map { local.modifiedAt > $0 } ?? true

                if !localChanged || local.modifiedAt < incoming.modifiedAt {
                    payload.entries[index] = incoming
                    outcome.pulled += 1
                } else if local.modifiedAt != incoming.modifiedAt {
                    // Edited in both places. Never drop either side: keep the
                    // local one and bring the other in beside it, so the user
                    // decides rather than the clock.
                    var copy = incoming
                    copy.id = UUID()
                    copy.name += " (conflicted copy)"
                    payload.entries.append(copy)
                    outcome.conflicts += 1
                }
            } else if state.syncedAt[record.id] == nil {
                payload.entries.append(incoming)
                outcome.pulled += 1
            }
            state.syncedAt[record.id] = incoming.modifiedAt
        }

        for id in changes.deletedIDs {
            if let index = payload.entries.firstIndex(where: { $0.id.uuidString == id }) {
                payload.entries.remove(at: index)
                outcome.deletedLocally += 1
            }
            state.syncedAt.removeValue(forKey: id)
        }

        // Push anything the server has not seen at this modification date.
        var toPush: [SyncRecord] = []
        for entry in payload.entries {
            let key = entry.id.uuidString
            if state.syncedAt[key] != entry.modifiedAt {
                toPush.append(SyncRecord(
                    id: key,
                    payload: try Self.seal(entry, dek: dek),
                    modifiedAt: entry.modifiedAt
                ))
            }
        }
        if !toPush.isEmpty {
            try await backend.save(toPush)
            for record in toPush { state.syncedAt[record.id] = record.modifiedAt }
            outcome.pushed = toPush.count
        }

        state.token = changes.token
        return outcome
    }

    /// Tells the remote store a wallet is gone, and forgets its bookkeeping.
    public func pushDeletion(of ids: [UUID], state: inout State) async throws {
        let keys = ids.map(\.uuidString)
        try await backend.delete(ids: keys)
        for key in keys { state.syncedAt.removeValue(forKey: key) }
    }
}
