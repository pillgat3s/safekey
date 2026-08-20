import Foundation

/// A user-defined folder for wallets — exclusive membership, unlike tags.
///
/// Entries reference a group by `id` rather than by name so renaming a group
/// does not have to touch every entry (and cannot silently split a group in two
/// if two groups end up with the same name).
public struct WalletGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The chain this group organises. Groups are scoped to one chain because
    /// a folder spanning Solana and Bitcoin wallets has no practical meaning —
    /// you group wallets *within* a network, not across them.
    public var chain: Chain
    /// `#RRGGBB`, or nil to use the app's accent colour.
    public var colorHex: String?
    /// Position within its chain.
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        chain: Chain,
        colorHex: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.chain = chain
        self.colorHex = colorHex
        self.sortIndex = sortIndex
    }

    /// Tolerates groups written before they were chain-scoped rather than
    /// failing the whole payload decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        chain = try container.decodeIfPresent(Chain.self, forKey: .chain) ?? .evm
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
    }

    /// Palette offered when creating a group.
    public static let palette = [
        "#0A84FF", "#30D158", "#FF9F0A", "#FF375F", "#BF5AF2", "#64D2FF", "#FFD60A", "#8E8E93",
    ]
}
