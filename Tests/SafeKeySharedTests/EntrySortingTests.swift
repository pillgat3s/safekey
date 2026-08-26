import XCTest
import CryptoKit
@testable import SafeKeyCore

/// The list's sort order, which both apps share.
final class EntrySortingTests: XCTestCase {
    private func entry(_ name: String, modified: TimeInterval) -> WalletEntry {
        var entry = WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: "s")
        entry.modifiedAt = Date(timeIntervalSince1970: modified)
        entry.createdAt = entry.modifiedAt
        return entry
    }

    private func settings(_ order: VaultSettings.SortOrder, descending: Bool) -> VaultSettings {
        var settings = VaultSettings()
        settings.sortOrder = order
        settings.sortDescending = descending
        return settings
    }

    /// Vault dates are whole seconds, so ties are ordinary — several wallets
    /// synced or created in the same second. Descending used to negate the
    /// ascending comparison, which answers "first comes before second" for
    /// *both* orderings of a tie: not a valid ordering, and Swift's sort is
    /// entitled to reorder ties arbitrarily on every pass — or trap.
    func testTiedDatesKeepTheirOrderWhenDescending() {
        let entries = [
            entry("A", modified: 100), entry("B", modified: 100),
            entry("C", modified: 100), entry("D", modified: 100),
        ]
        let sorted = settings(.dateModified, descending: true).sorted(entries)
        XCTAssertEqual(sorted.map(\.name), ["A", "B", "C", "D"], "ties must not shuffle")
    }

    func testDescendingIsTheExactReverseOfAscendingForDistinctDates() {
        let entries = [entry("Old", modified: 10), entry("Mid", modified: 20), entry("New", modified: 30)]
        let newestFirst = settings(.dateModified, descending: true).sorted(entries)
        let oldestFirst = settings(.dateModified, descending: false).sorted(entries)
        XCTAssertEqual(newestFirst.map(\.name), ["New", "Mid", "Old"])
        XCTAssertEqual(oldestFirst.map(\.name), ["Old", "Mid", "New"])
    }

    func testNameSortIsCaseInsensitiveBothWays() {
        let entries = [entry("banana", modified: 1), entry("Apple", modified: 2), entry("cherry", modified: 3)]
        XCTAssertEqual(
            settings(.name, descending: false).sorted(entries).map(\.name),
            ["Apple", "banana", "cherry"]
        )
        XCTAssertEqual(
            settings(.name, descending: true).sorted(entries).map(\.name),
            ["cherry", "banana", "Apple"]
        )
    }
}
