import Foundation
import CryptoKit

/// Merges a vault against a remote store, one wallet at a time.
///
/// Per-wallet rather than whole-vault on purpose. The vault is a single sealed
/// blob, and two blobs cannot be merged — whoever wrote last would silently
/// erase the other device's work. Sealing each wallet separately means a clash
/// costs one wallet, and even then the loser is kept rather than discarded.
///
/// A run is deliberately three steps — ``pull(state:)``, ``merge(_:into:state:)``,
/// ``push(_:state:)`` — rather than one. Only the first and last touch the
/// network; the merge in the middle is pure and synchronous, so the caller can
/// read the vault, merge, and write it back without ever awaiting in between.
/// Folded into a single `async` function it would have to snapshot the payload
/// before the fetch and write that snapshot back afterwards, discarding
/// anything the user changed while the fetch was in flight.
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

        /// Whether the merge changed the vault, and so whether it needs
        /// writing back. A run that only pushed leaves the file untouched.
        public var changedLocally: Bool {
            pulled > 0 || conflicts > 0 || deletedLocally > 0
        }
    }

    /// What a sync run needs to remember between runs, per vault.
    public struct State: Codable, Sendable, Equatable {
        /// The digest of a record whose contents we do not know — bookkeeping
        /// from before digests were kept. Never equal to a real one, so the
        /// record is simply sent again.
        static let unknownVersion = "?"

        public var token: Data?
        /// Record id → a digest of the version the store is known to hold.
        ///
        /// A digest rather than a date, because vault dates are whole seconds:
        /// an edit made in the same second as the last sync would look like the
        /// version already sent and would never leave the device. It is also
        /// what tells this device's own record coming back to it apart from a
        /// genuine edit on the other one — the difference between a quiet sync
        /// and a spurious "conflicted copy".
        ///
        /// Presence means the store holds that record, which is what stops a
        /// wallet deleted here from being adopted again as if it were new.
        public var agreed: [String: String]
        /// Records deleted here that the server has not been told about yet.
        ///
        /// Persisted rather than pushed and forgotten: a deletion that only
        /// exists in memory is lost if the app quits first, and the record
        /// would then sit in iCloud until some later full fetch handed it back
        /// as if it were new. Keyed the same way records are, so a group's
        /// tombstone carries the `group:` prefix.
        public var pendingDeletions: [String]

        public init(token: Data? = nil, agreed: [String: String] = [:], pendingDeletions: [String] = []) {
            self.token = token
            self.agreed = agreed
            self.pendingDeletions = pendingDeletions
        }

        enum CodingKeys: String, CodingKey {
            case token, agreed, pendingDeletions
            /// What this file used to hold: id → modification date.
            case syncedAt
        }

        /// Hand-written so bookkeeping from an older build still decodes.
        /// Falling back to a fresh state would forget which records the store
        /// holds, and the next fetch would hand every one of them back as new —
        /// including any deleted here before the upgrade.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decodeIfPresent(Data.self, forKey: .token)
            pendingDeletions = try container.decodeIfPresent([String].self, forKey: .pendingDeletions) ?? []
            if let agreed = try container.decodeIfPresent([String: String].self, forKey: .agreed) {
                self.agreed = agreed
            } else {
                // Dates cannot be turned into digests, so each record is sent
                // once more. Which records existed is the part worth keeping.
                let legacy = try container.decodeIfPresent([String: Date].self, forKey: .syncedAt) ?? [:]
                agreed = legacy.mapValues { _ in Self.unknownVersion }
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(token, forKey: .token)
            try container.encode(agreed, forKey: .agreed)
            try container.encode(pendingDeletions, forKey: .pendingDeletions)
        }

        /// Notes that a wallet is gone, to be pushed on the next run.
        public mutating func noteDeletion(walletID: UUID) {
            note(key: walletID.uuidString)
        }

        /// Notes that a group is gone. Its wallets are untouched — on the other
        /// device they simply stop being grouped.
        public mutating func noteDeletion(groupID: UUID) {
            note(key: VaultSync.groupPrefix + groupID.uuidString)
        }

        private mutating func note(key: String) {
            guard !pendingDeletions.contains(key) else { return }
            pendingDeletions.append(key)
        }
    }

    /// Everything one fetch brought back, carried from the network step to the
    /// merge step so the merge can run against the current payload.
    public struct Pulled: Sendable {
        let changes: SyncChanges
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

    /// A stable fingerprint of a wallet's contents.
    ///
    /// Taken over the encoded model rather than the sealed bytes: sealing uses
    /// a fresh nonce each time, so two seals of the same wallet share no bytes.
    static func version(of entry: WalletEntry) -> String {
        guard let data = try? VaultJSON.encoder().encode(entry) else {
            return State.unknownVersion + entry.id.uuidString
        }
        return digest(data)
    }

    static func version(of group: WalletGroup) -> String {
        guard let data = try? VaultJSON.encoder().encode(group) else {
            return State.unknownVersion + group.id.uuidString
        }
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    // MARK: - A run, in three steps

    /// Sends the deletions the server has not been told about, then fetches
    /// what changed there.
    ///
    /// Deletions go first so that a wallet deleted here is already gone from
    /// the server before this same run considers what the server holds.
    public func pull(state: inout State) async throws -> Pulled {
        if !state.pendingDeletions.isEmpty {
            let keys = state.pendingDeletions
            try await backend.delete(ids: keys)
            for key in keys { state.agreed.removeValue(forKey: key) }
            state.pendingDeletions.removeAll()
        }
        return Pulled(changes: try await backend.fetchChanges(since: state.token))
    }

    /// Folds what the server sent into `payload`. Pure and synchronous: the
    /// caller can read the vault, call this, and write it back with nothing
    /// able to interleave.
    @discardableResult
    public func merge(_ pulled: Pulled, into payload: inout VaultPayload, state: inout State) -> Outcome {
        var outcome = Outcome()
        let changes = pulled.changes

        if changes.isFullResync {
            // The store answered from scratch, so what we believed it held is
            // no longer evidence of anything — a zone that was deleted and
            // recreated takes every record with it. Rebuild the record of what
            // is up there from this answer alone; whatever is missing from it
            // goes back up with the pushes below.
            state.agreed = [:]
        }

        for record in changes.records where record.id.hasPrefix(Self.groupPrefix) {
            guard let incoming = try? Self.openGroup(record.payload, id: record.id, dek: dek) else { continue }
            let incomingVersion = Self.version(of: incoming)
            if let index = payload.groups.firstIndex(where: { $0.id == incoming.id }) {
                let local = payload.groups[index]
                let localVersion = Self.version(of: local)
                // Groups are small and rarely edited, so newest wins is enough
                // here — unlike a wallet, nothing irreplaceable is lost.
                //
                // When the clocks tie the digests decide. Vault dates are whole
                // seconds, so two devices renaming a group in the same second
                // have the same timestamp, and "newer" cannot separate them:
                // each would keep its own copy, push it, and be handed the
                // other's back for ever. Any rule settles it as long as both
                // devices reach the same answer without another round.
                let takesIncoming = local.modifiedAt < incoming.modifiedAt
                    || (local.modifiedAt == incoming.modifiedAt && localVersion < incomingVersion)
                if localVersion != incomingVersion, takesIncoming {
                    payload.groups[index] = incoming
                    outcome.pulled += 1
                }
            } else if state.agreed[record.id] == nil {
                payload.groups.append(incoming)
                outcome.pulled += 1
            }
            state.agreed[record.id] = incomingVersion
        }

        for record in changes.records where !record.id.hasPrefix(Self.groupPrefix) {
            guard let incoming = try? Self.open(record.payload, id: record.id, dek: dek) else {
                // A record we cannot open is not ours to interpret. Skipping it
                // is safer than deleting it: another device may hold the key.
                continue
            }
            let incomingVersion = Self.version(of: incoming)
            if let index = payload.entries.firstIndex(where: { $0.id == incoming.id }) {
                let localVersion = Self.version(of: payload.entries[index])
                guard localVersion != incomingVersion else {
                    // Byte for byte what we already hold — usually this
                    // device's own last push echoed back. Counting it as an
                    // arrival would rewrite the vault on every quiet sync.
                    state.agreed[record.id] = incomingVersion
                    continue
                }
                let agreed = state.agreed[record.id]
                let localChanged = agreed != localVersion
                // Whether the version on the server is a *new* one, or simply
                // the one we put there. A fetch hands back this device's own
                // writes, so without this an edit made after the last push
                // would collide with its own previous version.
                let remoteChanged = agreed != incomingVersion

                if !localChanged {
                    payload.entries[index] = incoming
                    outcome.pulled += 1
                } else if remoteChanged {
                    // Edited in both places. Never drop either side, whichever
                    // clock is ahead: keep the local one and bring the other in
                    // beside it, so the user decides rather than the clock.
                    var copy = incoming
                    copy.id = UUID()
                    copy.name += " (conflicted copy)"
                    payload.entries.append(copy)
                    outcome.conflicts += 1
                }
                // The remaining case is this device's own echo: nothing to do
                // here, and the newer local version goes up with the pushes.
            } else if state.agreed[record.id] == nil {
                payload.entries.append(incoming)
                outcome.pulled += 1
            }
            state.agreed[record.id] = incomingVersion
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
            state.agreed.removeValue(forKey: id)
            state.pendingDeletions.removeAll { $0 == id }
        }

        // Nothing may be left pointing at a group that is not here.
        //
        // A record can arrive naming a group this device deleted earlier, and
        // a conflicted copy is the case that sticks: it is a brand-new record
        // carrying the other side's group id, so no other device ever corrects
        // it. A wallet holding an id that is not in the file appears neither in
        // that group nor in the ungrouped list — it drops out of the way the
        // vault is browsed while still being in it.
        let knownGroups = Set(payload.groups.map(\.id))
        for index in payload.entries.indices {
            if let groupID = payload.entries[index].groupID, !knownGroups.contains(groupID) {
                payload.entries[index].groupID = nil
            }
        }

        state.token = changes.token
        return outcome
    }

    /// Records whose contents differ from what the store is known to hold,
    /// sealed and ready to send.
    public struct Pending: Sendable {
        public let records: [SyncRecord]
        /// The digest each record will have once the store has it.
        let versions: [String: String]

        public var count: Int { records.count }
        public var isEmpty: Bool { records.isEmpty }
    }

    public func pendingPushes(payload: VaultPayload, state: State) throws -> Pending {
        var records: [SyncRecord] = []
        var versions: [String: String] = [:]
        for entry in payload.entries {
            let key = entry.id.uuidString
            let version = Self.version(of: entry)
            if state.agreed[key] != version {
                records.append(SyncRecord(
                    id: key,
                    payload: try Self.seal(entry, dek: dek),
                    modifiedAt: entry.modifiedAt
                ))
                versions[key] = version
            }
        }
        for group in payload.groups {
            let key = Self.groupPrefix + group.id.uuidString
            let version = Self.version(of: group)
            if state.agreed[key] != version {
                records.append(SyncRecord(
                    id: key,
                    payload: try Self.seal(group, dek: dek),
                    modifiedAt: group.modifiedAt
                ))
                versions[key] = version
            }
        }
        return Pending(records: records, versions: versions)
    }

    /// Sends records up and records that the store now agrees with them.
    public func push(_ pending: Pending, state: inout State) async throws {
        guard !pending.isEmpty else { return }
        try await backend.save(pending.records)
        for (key, version) in pending.versions { state.agreed[key] = version }
    }

    /// The three steps back to back, for callers that hold the payload
    /// exclusively for the whole run — tests, and one-shot merges.
    public func run(payload: inout VaultPayload, state: inout State) async throws -> Outcome {
        let pulled = try await pull(state: &state)
        var outcome = merge(pulled, into: &payload, state: &state)
        let pending = try pendingPushes(payload: payload, state: state)
        try await push(pending, state: &state)
        outcome.pushed = pending.count
        return outcome
    }

    // MARK: - Joining and merging whole vaults

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
                state.agreed[record.id] = version(of: group)
            } else {
                guard let entry = try? open(record.payload, id: record.id, dek: dek) else { continue }
                payload.entries.append(entry)
                state.agreed[record.id] = version(of: entry)
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
    ///
    /// Refuses when iCloud already holds a *different* vault. Overwriting the
    /// header there would strand that vault's records permanently: they are
    /// sealed under a key that only its header carries, so replacing it makes
    /// them unopenable by anyone, including the device that wrote them.
    ///
    /// `replacingAnotherVault` is for the two cases where the user has decided
    /// exactly that — merging the iCloud vault into this one, or replacing it
    /// outright. Both re-seal the wallets under this vault's key afterwards, so
    /// the header they leave behind is the right one for what is in the zone.
    public func publishVault(header: VaultHeader, replacingAnotherVault: Bool = false) async throws {
        if !replacingAnotherVault,
           let existing = try await backend.fetchVault(),
           existing.vaultID != header.vaultID {
            throw SyncError.differentVault(remote: existing.vaultID, local: header.vaultID)
        }
        let encoded = try VaultJSON.encoder().encode(header)
        try await backend.saveVault(SyncedVault(vaultID: header.vaultID, header: encoded))
    }
}
