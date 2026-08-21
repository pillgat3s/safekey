import Foundation
import SafeKeyCore

extension VaultSettings {
    /// Sorts wallets by the chosen field and direction.
    ///
    /// Lives here rather than in either app so the Mac list and the iPhone
    /// list cannot drift into sorting the same vault differently.
    func sorted(_ entries: [WalletEntry]) -> [WalletEntry] {
        let descending = effectiveSortDescending
        return entries.sorted { first, second in
            let ascending: Bool
            switch sortOrder {
            case .dateModified:
                ascending = first.modifiedAt < second.modifiedAt
            case .dateCreated:
                ascending = first.createdAt < second.createdAt
            case .name:
                ascending = first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            case .chain:
                ascending = first.chain.displayName.localizedCaseInsensitiveCompare(second.chain.displayName)
                    == .orderedAscending
            }
            return descending ? !ascending : ascending
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
