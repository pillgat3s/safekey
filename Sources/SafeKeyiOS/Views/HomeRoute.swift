import SwiftUI
import SafeKeyCore

/// One step of the iPhone home screen's navigation, as a value: a filtered
/// list, or a wallet. Links push values rather than views so the stack can be
/// captured when the vault locks and rebuilt when it opens again, which is
/// what puts you back on the wallet you were reading instead of the home grid.
enum HomeRoute: Hashable {
    case list(EntryFilter)
    case entry(WalletEntry.ID)

    /// Whether the step still leads somewhere in this vault. A wallet or a
    /// group can vanish while the app is locked — deleted on another device
    /// and pulled by the sync that runs at unlock — and pushing a screen for
    /// it would land on "nothing here".
    @MainActor
    func isValid(in session: VaultSession) -> Bool {
        switch self {
        case .list(.group(let id)): session.group(id: id) != nil
        case .list: true
        case .entry(let id): session.entry(id: id) != nil
        }
    }
}

extension EntryFilter {
    /// The list's title, resolved against the vault because a group's name
    /// lives there.
    @MainActor
    func title(in session: VaultSession) -> String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .seedPhrases: "Seed Phrases"
        case .privateKeys: "Private Keys"
        case .chain(let chain): chain.displayName
        case .group(let id): session.group(id: id)?.name ?? "Group"
        }
    }
}

extension Array where Element == HomeRoute {
    /// The longest leading run of steps that still resolve. A stack cannot
    /// skip a level, so the first stale step ends the path.
    @MainActor
    func validated(in session: VaultSession) -> [HomeRoute] {
        Array(prefix { $0.isValid(in: session) })
    }
}

/// Where the user was when the vault locked, kept as identifiers only, so the
/// same screen comes back at unlock. Nothing here can open a wallet: the
/// session and its key are discarded the moment the app leaves the foreground.
struct ResumeState {
    var homePath: [HomeRoute] = []
    var splitSelection: VaultSplitView.Selection?
    var splitPath: [HomeRoute] = []

    /// The same state with anything that no longer resolves dropped.
    @MainActor
    func validated(in session: VaultSession) -> ResumeState {
        var state = self
        state.homePath = homePath.validated(in: session)
        if case .group(let id) = splitSelection, session.group(id: id) == nil {
            state.splitSelection = nil
        }
        state.splitPath = splitPath.validated(in: session)
        return state
    }
}
