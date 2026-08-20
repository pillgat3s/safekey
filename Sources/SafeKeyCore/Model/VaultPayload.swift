import Foundation

/// Root of the encrypted vault payload. Everything inside this struct is
/// encrypted at rest; nothing here is ever written to disk in plaintext.
public struct VaultPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var entries: [WalletEntry]
    public var settings: VaultSettings
    public var groups: [WalletGroup]

    public init(
        schemaVersion: Int = 1,
        entries: [WalletEntry] = [],
        settings: VaultSettings = VaultSettings(),
        groups: [WalletGroup] = []
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.settings = settings
        self.groups = groups
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
    }
}
