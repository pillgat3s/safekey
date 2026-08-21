import Foundation

/// User-configurable security behavior. Lives inside the encrypted payload so
/// an attacker cannot read or tamper with it while the vault is locked.
public struct VaultSettings: Codable, Sendable, Equatable {
    /// Seconds of inactivity before the vault locks itself. `nil` = never.
    public var autoLockSeconds: Int?
    /// Lock when the Mac goes to sleep.
    public var lockOnSleep: Bool
    /// Lock when the screen locks / screensaver starts.
    public var lockOnScreenLock: Bool
    /// Seconds before a copied secret is cleared from the clipboard. `nil` = never clear.
    public var clipboardClearSeconds: Int?
    /// Re-authentication requirement for revealing a secret in the detail view.
    public var revealPolicy: RevealPolicy
    /// Default chain preselected for new entries.
    public var defaultChain: Chain
    /// Sort order for the entry list.
    public var sortOrder: SortOrder
    /// Mirror the encrypted vault to iCloud Drive after every change.
    public var cloudBackupEnabled: Bool
    /// Order of the home screen's category tiles. Empty means the built-in
    /// order. Stored as identifiers rather than indexes so a tile added in a
    /// later version simply lands at the end instead of shifting the rest.
    public var homeTileOrder: [HomeTile]
    /// Tiles the user has hidden from the home screen.
    public var hiddenHomeTiles: [HomeTile]
    /// Order of the chain rows. Chains not listed keep their natural order
    /// after the ones that are.
    public var chainOrder: [Chain]

    /// The fixed categories on the home screen.
    public enum HomeTile: String, Codable, Sendable, Equatable, CaseIterable {
        case all, favorites, seedPhrases, privateKeys
    }

    public enum RevealPolicy: Codable, Sendable, Equatable {
        case never
        case everyTime
        case afterMinutes(Int)
    }

    public enum SortOrder: String, Codable, Sendable, Equatable, CaseIterable {
        case dateModified
        case name
        case chain
    }

    public init(
        autoLockSeconds: Int? = 300,
        lockOnSleep: Bool = true,
        lockOnScreenLock: Bool = true,
        clipboardClearSeconds: Int? = 30,
        revealPolicy: RevealPolicy = .never,
        defaultChain: Chain = .evm,
        sortOrder: SortOrder = .dateModified,
        cloudBackupEnabled: Bool = false,
        homeTileOrder: [HomeTile] = [],
        hiddenHomeTiles: [HomeTile] = [],
        chainOrder: [Chain] = []
    ) {
        self.autoLockSeconds = autoLockSeconds
        self.lockOnSleep = lockOnSleep
        self.lockOnScreenLock = lockOnScreenLock
        self.clipboardClearSeconds = clipboardClearSeconds
        self.revealPolicy = revealPolicy
        self.defaultChain = defaultChain
        self.sortOrder = sortOrder
        self.cloudBackupEnabled = cloudBackupEnabled
        self.homeTileOrder = homeTileOrder
        self.hiddenHomeTiles = hiddenHomeTiles
        self.chainOrder = chainOrder
    }

    /// Hand-written so settings added in a later version decode as their
    /// defaults instead of failing. A synthesised decoder throws on any missing
    /// key, which would make every vault written by an earlier build look
    /// corrupt the moment a new setting is introduced.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoLockSeconds = try container.decodeIfPresent(Int.self, forKey: .autoLockSeconds) ?? 300
        lockOnSleep = try container.decodeIfPresent(Bool.self, forKey: .lockOnSleep) ?? true
        lockOnScreenLock = try container.decodeIfPresent(Bool.self, forKey: .lockOnScreenLock) ?? true
        clipboardClearSeconds = try container.decodeIfPresent(Int.self, forKey: .clipboardClearSeconds) ?? 30
        revealPolicy = try container.decodeIfPresent(RevealPolicy.self, forKey: .revealPolicy) ?? .never
        defaultChain = try container.decodeIfPresent(Chain.self, forKey: .defaultChain) ?? .evm
        sortOrder = try container.decodeIfPresent(SortOrder.self, forKey: .sortOrder) ?? .dateModified
        cloudBackupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudBackupEnabled) ?? false
        homeTileOrder = try container.decodeIfPresent([HomeTile].self, forKey: .homeTileOrder) ?? []
        hiddenHomeTiles = try container.decodeIfPresent([HomeTile].self, forKey: .hiddenHomeTiles) ?? []
        chainOrder = try container.decodeIfPresent([Chain].self, forKey: .chainOrder) ?? []
    }

    /// Applies the stored order to a set of items, keeping anything unlisted in
    /// its natural position afterwards. Shared by the tiles and the chain rows
    /// so both behave the same when something new appears.
    public static func ordered<T: Equatable>(_ items: [T], by order: [T]) -> [T] {
        let known = order.filter { items.contains($0) }
        let rest = items.filter { !known.contains($0) }
        return known + rest
    }
}
