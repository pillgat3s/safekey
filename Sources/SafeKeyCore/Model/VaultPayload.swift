import Foundation

/// Root of the encrypted vault payload. Everything inside this struct is
/// encrypted at rest; nothing here is ever written to disk in plaintext.
public struct VaultPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var entries: [WalletEntry]
    public var settings: VaultSettings
    public var groups: [WalletGroup]
    /// The shared groups this device belongs to, with their keys. Local to the
    /// vault: sync neither sends nor receives these, it discovers them from
    /// the account instead. See ``SharedGroupMembership``.
    public var sharedGroups: [SharedGroupMembership]

    public init(
        schemaVersion: Int = 1,
        entries: [WalletEntry] = [],
        settings: VaultSettings = VaultSettings(),
        groups: [WalletGroup] = [],
        sharedGroups: [SharedGroupMembership] = []
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.settings = settings
        self.groups = groups
        self.sharedGroups = sharedGroups
    }

    /// Hand-written so that fields added after a vault was created decode as
    /// empty instead of failing. A synthesised decoder throws on a missing key,
    /// which would make an older vault look corrupt.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        entries = try container.decodeIfPresent([WalletEntry].self, forKey: .entries) ?? []
        settings = try container.decodeIfPresent(VaultSettings.self, forKey: .settings) ?? VaultSettings()
        groups = try container.decodeIfPresent([WalletGroup].self, forKey: .groups) ?? []
        sharedGroups = try container.decodeIfPresent([SharedGroupMembership].self, forKey: .sharedGroups) ?? []
    }
}
