import Foundation

/// A single stored wallet secret: a seed phrase or a private key.
public struct WalletEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var chain: Chain
    public var kind: SecretKind
    /// The secret material itself (seed phrase words separated by single
    /// spaces, or the raw private key string). Only ever held in memory
    /// while the vault is unlocked.
    public var secret: String
    public var publicAddress: String?
    public var notes: String
    public var tags: [String]
    /// Group membership, or nil for ungrouped. Optional so vaults written
    /// before groups existed still decode.
    public var groupID: UUID?
    public var favorite: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        chain: Chain,
        kind: SecretKind,
        secret: String,
        publicAddress: String? = nil,
        notes: String = "",
        tags: [String] = [],
        groupID: UUID? = nil,
        favorite: Bool = false,
        createdAt: Date = .vaultNow(),
        modifiedAt: Date = .vaultNow()
    ) {
        self.id = id
        self.name = name
        self.chain = chain
        self.kind = kind
        self.secret = secret
        self.publicAddress = publicAddress
        self.notes = notes
        self.tags = tags
        self.groupID = groupID
        self.favorite = favorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

extension WalletEntry: CustomDebugStringConvertible {
    /// Redacted — the secret must never leak into logs or crash reports.
    public var debugDescription: String {
        "WalletEntry(\(id), name: \(name), chain: \(chain.displayName), kind: \(kind.displayName), secret: <redacted>)"
    }
}
