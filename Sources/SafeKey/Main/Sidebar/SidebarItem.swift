import Foundation
import SafeKeyCore

enum SidebarItem: Hashable {
    case all
    case favorites
    case seedPhrases
    case privateKeys
    case group(UUID)
    /// Loose entries within one chain. Groups are chain-scoped, so "ungrouped"
    /// only means anything relative to a chain.
    case ungrouped(Chain)
    case chain(Chain)
    case tag(String)

    func matches(_ entry: WalletEntry) -> Bool {
        switch self {
        case .all: true
        case .favorites: entry.favorite
        case .seedPhrases: entry.kind.isSeedPhrase
        case .privateKeys: !entry.kind.isSeedPhrase
        case .group(let id): entry.groupID == id
        case .ungrouped(let chain): entry.chain == chain && entry.groupID == nil
        case .chain(let chain): entry.chain == chain
        case .tag(let tag): entry.tags.contains(tag)
        }
    }

    /// Groups are titled by the session, which knows their names.
    @MainActor
    func title(in session: VaultSession) -> String {
        switch self {
        case .group(let id): session.group(id: id)?.name ?? "Group"
        default: staticTitle
        }
    }

    var staticTitle: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .seedPhrases: "Seed Phrases"
        case .privateKeys: "Private Keys"
        case .group: "Group"
        case .ungrouped(let chain): "\(chain.displayName) · Ungrouped"
        case .chain(let chain): chain.displayName
        case .tag(let tag): tag
        }
    }

    /// The chain this item is scoped to, if any — used to preselect the chain
    /// when creating a group from the current context.
    @MainActor
    func chainContext(in session: VaultSession) -> Chain? {
        switch self {
        case .chain(let chain), .ungrouped(let chain): chain
        case .group(let id): session.group(id: id)?.chain
        default: nil
        }
    }
}
