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
    /// An SF Symbol name, or a single emoji. `nil` falls back to a folder.
    /// Stored as a plain string so the format stays portable — a future
    /// Windows client can show the emoji and substitute its own glyph for a
    /// symbol name it does not recognise.
    public var icon: String?
    /// Position within its chain.
    public var sortIndex: Int
    /// When this group was last changed, so sync can tell which side is newer.
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        chain: Chain,
        colorHex: String? = nil,
        icon: String? = nil,
        sortIndex: Int = 0,
        modifiedAt: Date = .vaultNow()
    ) {
        self.id = id
        self.name = name
        self.chain = chain
        self.colorHex = colorHex
        self.icon = icon
        self.sortIndex = sortIndex
        self.modifiedAt = modifiedAt
    }

    /// Tolerates groups written before they were chain-scoped rather than
    /// failing the whole payload decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        chain = try container.decodeIfPresent(Chain.self, forKey: .chain) ?? .evm
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        // Groups written before sync existed have no date; treating them as
        // ancient means a dated copy from another device wins, which is the
        // safe way round.
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
    }

    /// SF Symbols offered when picking a group icon — a small, legible set
    /// rather than the whole catalogue, which is unusable in a picker.
    public static let symbolChoices = [
        "folder.fill", "star.fill", "flame.fill", "bolt.fill", "leaf.fill",
        "banknote.fill", "chart.line.uptrend.xyaxis", "shield.fill", "lock.fill",
        "briefcase.fill", "house.fill", "cart.fill", "gift.fill", "crown.fill",
        "cube.fill", "sparkles", "globe", "pin.fill",
    ]

    /// Palette offered when creating a group.
    public static let palette = [
        "#0A84FF", "#30D158", "#FF9F0A", "#FF375F", "#BF5AF2", "#64D2FF", "#FFD60A", "#8E8E93",
    ]
}
