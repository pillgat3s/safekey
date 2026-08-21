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

/// What a remote store hands back for an incremental fetch.
public struct SyncChanges: Sendable, Equatable {
    public let records: [SyncRecord]
    /// IDs deleted remotely. Without these a wallet deleted on one device
    /// reappears from the other on the next sync.
    public let deletedIDs: [String]
    /// Opaque resume point, stored so the next fetch is incremental.
    public let token: Data?

    public init(records: [SyncRecord], deletedIDs: [String], token: Data?) {
        self.records = records
        self.deletedIDs = deletedIDs
        self.token = token
    }
}

/// The remote half of sync, behind a protocol so the merge logic can be tested
/// without a network, an Apple ID, or a CloudKit container.
public protocol SyncBackend: Sendable {
    func fetchChanges(since token: Data?) async throws -> SyncChanges
    func save(_ records: [SyncRecord]) async throws
    func delete(ids: [String]) async throws
}

public enum SyncError: Error, Equatable, Sendable {
    /// The remote vault is a different vault. Merging two vaults would mean
    /// decrypting one with the other's key, which cannot work — the user has
    /// to choose which vault wins instead.
    case differentVault(remote: UUID, local: UUID)
    case unavailable(String)
}
