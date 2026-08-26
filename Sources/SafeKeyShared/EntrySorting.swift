import Foundation
import SafeKeyCore

extension VaultSettings {
    /// Sorts wallets by the chosen field and direction.
    ///
    /// Lives here rather than in either app so the Mac list and the iPhone
    /// list cannot drift into sorting the same vault differently.
    ///
    /// Descending swaps the operands rather than negating the result. Negation
    /// answers "yes, first comes before second" for two *equal* elements — and
    /// ties are ordinary here, because vault dates are whole seconds — which is
    /// not a valid ordering: Swift's sort may reorder equal rows arbitrarily on
    /// every pass, and is entitled to trap on it.
    func sorted(_ entries: [WalletEntry]) -> [WalletEntry] {
        let descending = effectiveSortDescending
        return entries.sorted { lhs, rhs in
            let (first, second) = descending ? (rhs, lhs) : (lhs, rhs)
            switch sortOrder {
            case .dateModified:
                return first.modifiedAt < second.modifiedAt
            case .dateCreated:
                return first.createdAt < second.createdAt
            case .name:
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            case .chain:
                return first.chain.displayName.localizedCaseInsensitiveCompare(second.chain.displayName)
                    == .orderedAscending
            }
        }
    }

    /// The date a bucket header should describe, when the list is date-sorted.
    func bucketDate(for entry: WalletEntry) -> Date? {
        switch sortOrder {
        case .dateModified: entry.modifiedAt
        case .dateCreated: entry.createdAt
        case .name, .chain: nil
        }
    }
}
