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

    /// Groups share the wallet zone, told apart by a prefix on the record name.
    /// One record stream rather than two keeps deletions and change tokens
    /// working the same way for both.
    static let groupPrefix = "group:"

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

    static func seal(_ group: WalletGroup, dek: SymmetricKey) throws -> Data {
        let plaintext = try VaultJSON.encoder().encode(group)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: dek,
            authenticating: Data((groupPrefix + group.id.uuidString).utf8)
        )
        guard let combined = sealed.combined else { throw VaultError.cryptoFailure }
        return combined
    }

    static func openGroup(_ payload: Data, id: String, dek: SymmetricKey) throws -> WalletGroup {
        let box = try AES.GCM.SealedBox(combined: payload)
        let plaintext = try AES.GCM.open(box, using: dek, authenticating: Data(id.utf8))
        return try VaultJSON.decoder().decode(WalletGroup.self, from: plaintext)
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

        for record in changes.records where record.id.hasPrefix(Self.groupPrefix) {
            guard let incoming = try? Self.openGroup(record.payload, id: record.id, dek: dek) else { continue }
            if let index = payload.groups.firstIndex(where: { $0.id == incoming.id }) {
                // Groups are small and rarely edited, so newest wins is enough
                // here — unlike a wallet, nothing irreplaceable is lost.
                if payload.groups[index].modifiedAt < incoming.modifiedAt {
                    payload.groups[index] = incoming
                    outcome.pulled += 1
                }
            } else if state.syncedAt[record.id] == nil {
                payload.groups.append(incoming)
                outcome.pulled += 1
            }
            state.syncedAt[record.id] = incoming.modifiedAt
        }

        for record in changes.records where !record.id.hasPrefix(Self.groupPrefix) {
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
            if id.hasPrefix(Self.groupPrefix) {
                let raw = String(id.dropFirst(Self.groupPrefix.count))
                if let index = payload.groups.firstIndex(where: { $0.id.uuidString == raw }) {
                    payload.groups.remove(at: index)
                    // Wallets keep existing; they simply stop being grouped.
                    for entryIndex in payload.entries.indices
                    where payload.entries[entryIndex].groupID?.uuidString == raw {
                        payload.entries[entryIndex].groupID = nil
                    }
                    outcome.deletedLocally += 1
                }
            } else if let index = payload.entries.firstIndex(where: { $0.id.uuidString == id }) {
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
        for group in payload.groups {
            let key = Self.groupPrefix + group.id.uuidString
            if state.syncedAt[key] != group.modifiedAt {
                toPush.append(SyncRecord(
                    id: key,
                    payload: try Self.seal(group, dek: dek),
                    modifiedAt: group.modifiedAt
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

    /// Opens the vault that is in iCloud using its master password, and
    /// returns it whole — header, wallets and all.
    ///
    /// This is what lets a second device join by typing the master password,
    /// rather than shuttling a backup file around. The header carries the salt
    /// and the wrapped data key, so the password is enough to derive
    /// everything; without the header a device that knows the password still
    /// has nothing to derive from.
    public static func adoptRemoteVault(
        backend: any SyncBackend,
        password: String
    ) async throws -> (unlocked: Vault.Unlocked, state: State) {
        guard let remote = try await backend.fetchVault() else {
            throw SyncError.unavailable("There is no vault in iCloud yet.")
        }
        let header = try VaultJSON.decoder().decode(VaultHeader.self, from: remote.header)
        // Wrong password surfaces here, as a GCM failure to unwrap.
        let kek = try KeyDerivation.deriveKey(password: password, params: header.kdf)
        let dek: SymmetricKey
        do {
            dek = try VaultCrypto.unwrapDEK(header.wrappedDEK, under: kek)
        } catch {
            throw VaultError.wrongPassword
        }

        var payload = VaultPayload()
        var state = State()
        let changes = try await backend.fetchChanges(since: nil)
        for record in changes.records {
            if record.id.hasPrefix(groupPrefix) {
                guard let group = try? openGroup(record.payload, id: record.id, dek: dek) else { continue }
                payload.groups.append(group)
                state.syncedAt[record.id] = group.modifiedAt
            } else {
                guard let entry = try? open(record.payload, id: record.id, dek: dek) else { continue }
                payload.entries.append(entry)
                state.syncedAt[record.id] = entry.modifiedAt
            }
        }
        state.token = changes.token
        return (Vault.Unlocked(header: header, payload: payload, dek: dek), state)
    }

    /// Combines the vault in iCloud into this one, keeping every wallet from
    /// both.
    ///
    /// Both sets are decrypted in memory on a device that has legitimately
    /// unlocked both — this one by being open, the other by its password being
    /// supplied here — so nothing is revealed that this device did not already
    /// have. The incoming wallets are re-sealed under *this* vault's data key,
    /// so afterwards there is one vault, opened by this vault's password.
    ///
    /// Wallets already here win on a shared id; a wallet is matched by id, not
    /// by name, so two genuinely different wallets that happen to share a name
    /// both survive.
    public static func mergeRemoteVault(
        backend: any SyncBackend,
        password: String,
        into local: Vault.Unlocked
    ) async throws -> (merged: Vault.Unlocked, adopted: Int) {
        guard let remote = try await backend.fetchVault() else {
            throw SyncError.unavailable("There is no vault in iCloud yet.")
        }
        let header = try VaultJSON.decoder().decode(VaultHeader.self, from: remote.header)
        let kek = try KeyDerivation.deriveKey(password: password, params: header.kdf)
        let remoteDEK: SymmetricKey
        do {
            remoteDEK = try VaultCrypto.unwrapDEK(header.wrappedDEK, under: kek)
        } catch {
            throw VaultError.wrongPassword
        }

        var merged = local
        let existing = Set(local.payload.entries.map(\.id))
        var adopted = 0
        let changes = try await backend.fetchChanges(since: nil)

        // Groups first, so a wallet absorbed below still finds the group it
        // belonged to rather than arriving loose.
        let knownGroupIDs = Set(local.payload.groups.map(\.id))
        for record in changes.records where record.id.hasPrefix(groupPrefix) {
            guard let group = try? openGroup(record.payload, id: record.id, dek: remoteDEK) else { continue }
            guard !knownGroupIDs.contains(group.id) else { continue }
            merged.payload.groups.append(group)
        }

        for record in changes.records where !record.id.hasPrefix(groupPrefix) {
            guard let entry = try? open(record.payload, id: record.id, dek: remoteDEK) else { continue }
            guard !existing.contains(entry.id) else { continue }
            merged.payload.entries.append(entry)
            adopted += 1
        }

        // Anything still pointing at a group that did not come across is
        // cleared, so no wallet holds an id that is not in the file.
        let knownGroups = Set(merged.payload.groups.map(\.id))
        for index in merged.payload.entries.indices {
            if let groupID = merged.payload.entries[index].groupID, !knownGroups.contains(groupID) {
                merged.payload.entries[index].groupID = nil
            }
        }
        return (merged, adopted)
    }

    /// Publishes this vault's header so another device can join with just the
    /// master password.
    public func publishVault(header: VaultHeader) async throws {
        let encoded = try VaultJSON.encoder().encode(header)
        try await backend.saveVault(SyncedVault(vaultID: header.vaultID, header: encoded))
    }

    /// Tells the remote store a wallet is gone, and forgets its bookkeeping.
    public func pushDeletion(of ids: [UUID], state: inout State) async throws {
        let keys = ids.map(\.uuidString)
        try await backend.delete(ids: keys)
        for key in keys { state.syncedAt.removeValue(forKey: key) }
    }
}
