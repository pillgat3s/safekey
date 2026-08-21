import Foundation

/// One wallet as it travels: an opaque sealed blob plus the metadata needed to
/// merge it. The payload is AES-GCM under the vault's data key, so a sync
/// backend — Apple's or anyone else's — only ever holds ciphertext.
public struct SyncRecord: Sendable, Equatable, Hashable {
    /// The wallet's UUID, stable across devices, so the same wallet edited on
    /// two devices produces one record rather than two.
    public let id: String
    /// AES-GCM(entry JSON) under the vault DEK.
    public let payload: Data
    /// When the wallet was last edited, used to decide which side wins.
    public let modifiedAt: Date

    public init(id: String, payload: Data, modifiedAt: Date) {
        self.id = id
        self.payload = payload
        self.modifiedAt = modifiedAt
    }
}

/// The vault's own header, synced alongside the wallets.
///
/// Without it a second device holds records it can never open: the data key
/// is wrapped inside the header, so a device that has the master password but
/// not the header still cannot derive anything. This is the same material an
/// exported backup already contains — a salt, KDF parameters, and a key
/// wrapped under the password — so putting it in the user's private database
/// adds no exposure that exporting a backup does not.
public struct SyncedVault: Sendable, Equatable {
    public let vaultID: UUID
    /// The encoded `VaultHeader`.
    public let header: Data

    public init(vaultID: UUID, header: Data) {
        self.vaultID = vaultID
        self.header = header
    }
}

/// What a remote store hands back for an incremental fetch.
public struct SyncChanges: Sendable, Equatable {
    public let records: [SyncRecord]
    /// IDs deleted remotely. Without these a wallet deleted on one device
    /// reappears from the other on the next sync.
    public let deletedIDs: [String]
    /// Opaque resume point, stored so the next fetch is incremental.
    public let token: Data?
    /// True when the store answered from scratch rather than from our resume
    /// point — a first fetch, or a token the server would not accept because
    /// the zone was deleted and recreated in the meantime.
    ///
    /// It matters because our record of what the store already holds is then
    /// worthless: wallets we believe are safely up there may have gone with the
    /// old zone, and only what this answer contains is actually known to exist.
    public let isFullResync: Bool

    public init(records: [SyncRecord], deletedIDs: [String], token: Data?, isFullResync: Bool = false) {
        self.records = records
        self.deletedIDs = deletedIDs
        self.token = token
        self.isFullResync = isFullResync
    }
}

/// The remote half of sync, behind a protocol so the merge logic can be tested
/// without a network, an Apple ID, or a CloudKit container.
public protocol SyncBackend: Sendable {
    func fetchChanges(since token: Data?) async throws -> SyncChanges
    func save(_ records: [SyncRecord]) async throws
    func delete(ids: [String]) async throws
    /// The vault currently in the remote store, if any.
    func fetchVault() async throws -> SyncedVault?
    func saveVault(_ vault: SyncedVault) async throws
}

public enum SyncError: Error, Equatable, Sendable {
    /// The remote vault is a different vault. Merging two vaults would mean
    /// decrypting one with the other's key, which cannot work — the user has
    /// to choose which vault wins instead.
    case differentVault(remote: UUID, local: UUID)
    case unavailable(String)
}

/// A sync backend that also knows about the account it is talking to.
///
/// Split from ``SyncBackend`` so the coordinator can be driven by a stand-in
/// in tests: everything it needs from CloudKit is on this protocol, and
/// nothing above it names `CKContainer`.
public protocol CloudBackend: SyncBackend {
    /// Vault ids seen on records this device cannot open.
    var foreignVaultIDs: Set<UUID> { get async }
    /// Removes this vault's zone entirely.
    func removeEverything() async throws
}
