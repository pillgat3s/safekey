import Foundation
import CryptoKit
import LocalAuthentication
import Observation
import SafeKeyCore

/// The unlocked vault: holds the decrypted payload and the DEK, persists every
/// mutation through `VaultStore`. Dropped entirely on lock so ARC releases the
/// secrets.
@MainActor
@Observable
final class VaultSession {
    private(set) var unlocked: Vault.Unlocked
    private let store: VaultStore
    /// Called after every successful persist with the exact bytes written, so
    /// the caller can pin the trusted anchor to precisely what is on disk.
    private let onPersist: (Data, Vault.Unlocked) -> Void
    /// Surfaced in an alert when a background save fails; nil otherwise.
    var saveError: String?
    /// Set when this session came from creating the vault, so first-run offers
    /// (biometric unlock) can be made once rather than on every unlock.
    var isNewlyCreated = false

    init(
        unlocked: Vault.Unlocked,
        store: VaultStore,
        onPersist: @escaping (Data, Vault.Unlocked) -> Void = { _, _ in }
    ) {
        self.unlocked = unlocked
        self.store = store
        self.onPersist = onPersist
    }

    var entries: [WalletEntry] { unlocked.payload.entries }
    var settings: VaultSettings { unlocked.payload.settings }
    var header: VaultHeader { unlocked.header }

    func entry(id: WalletEntry.ID) -> WalletEntry? {
        entries.first { $0.id == id }
    }

    var allTags: [String] {
        Array(Set(entries.flatMap(\.tags))).sorted()
    }

    /// Existing tags ordered by how often they are used, for autocomplete —
    /// the ones you reach for most should be offered first.
    var tagsByFrequency: [String] {
        var counts: [String: Int] = [:]
        for tag in entries.flatMap(\.tags) {
            counts[tag, default: 0] += 1
        }
        return counts.sorted {
            $0.value == $1.value
                ? $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                : $0.value > $1.value
        }.map(\.key)
    }

    // MARK: - Groups

    var groups: [WalletGroup] {
        unlocked.payload.groups.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Groups belonging to one chain — the only grouping that makes sense.
    func groups(for chain: Chain) -> [WalletGroup] {
        groups.filter { $0.chain == chain }
    }

    func group(id: UUID?) -> WalletGroup? {
        guard let id else { return nil }
        return unlocked.payload.groups.first { $0.id == id }
    }

    /// True when a chain has grouped entries *and* loose ones, so the sidebar
    /// only shows an "Ungrouped" row where it is meaningful.
    func hasUngroupedEntries(in chain: Chain) -> Bool {
        !groups(for: chain).isEmpty && entries.contains { $0.chain == chain && $0.groupID == nil }
    }

    @discardableResult
    func addGroup(name: String, chain: Chain, colorHex: String?, icon: String? = nil) -> WalletGroup {
        let group = WalletGroup(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            chain: chain,
            colorHex: colorHex,
            icon: icon,
            sortIndex: (unlocked.payload.groups.filter { $0.chain == chain }.map(\.sortIndex).max() ?? -1) + 1
        )
        unlocked.payload.groups.append(group)
        persist()
        return group
    }

    func updateGroup(_ group: WalletGroup) {
        guard let index = unlocked.payload.groups.firstIndex(where: { $0.id == group.id }) else { return }
        var group = group
        group.modifiedAt = .vaultNow()
        unlocked.payload.groups[index] = group
        persist()
    }

    /// Removes the group and un-assigns its members. Entries are never deleted
    /// alongside a group — losing wallets because a folder was tidied away
    /// would be unforgivable in a vault.
    func deleteGroup(id: UUID) {
        unlocked.payload.groups.removeAll { $0.id == id }
        for index in unlocked.payload.entries.indices where unlocked.payload.entries[index].groupID == id {
            unlocked.payload.entries[index].groupID = nil
        }
        persist()
    }

    func move(entryID: WalletEntry.ID, toGroup groupID: UUID?) {
        guard let index = unlocked.payload.entries.firstIndex(where: { $0.id == entryID }) else { return }
        unlocked.payload.entries[index].groupID = groupID
        unlocked.payload.entries[index].modifiedAt = .vaultNow()
        persist()
    }

    var usedChains: [Chain] {
        var seen: [Chain] = []
        for entry in entries where !seen.contains(entry.chain) {
            seen.append(entry.chain)
        }
        return seen.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Mutations (each persists immediately)

    func upsert(_ entry: WalletEntry) {
        var entry = entry
        entry.modifiedAt = .vaultNow()
        if let index = unlocked.payload.entries.firstIndex(where: { $0.id == entry.id }) {
            unlocked.payload.entries[index] = entry
        } else {
            unlocked.payload.entries.append(entry)
        }
        persist()
    }

    func delete(id: WalletEntry.ID) {
        unlocked.payload.entries.removeAll { $0.id == id }
        persist()
    }

    func toggleFavorite(id: WalletEntry.ID) {
        guard var entry = entry(id: id) else { return }
        entry.favorite.toggle()
        upsert(entry)
    }

    /// Replaces the wallets with a merged set from sync and writes it out.
    /// Separate from `upsert` because sync produces a whole payload at once,
    /// and saving per wallet would rewrite the vault once per change.
    func adoptSynced(_ merged: VaultPayload) {
        unlocked.payload = merged
        persist()
    }

    func updateSettings(_ newSettings: VaultSettings) {
        unlocked.payload.settings = newSettings
        persist()
    }

    func updateHeader(_ mutate: (inout VaultHeader) -> Void) {
        mutate(&unlocked.header)
        persist()
    }

    /// Adopts a re-wrapped unlocked state (password change, device-factor
    /// enable/disable) and persists it. Validating before writing means a
    /// re-wrap that produced something we cannot reopen never reaches disk.
    func adopt(_ newUnlocked: Vault.Unlocked) async throws {
        await flushPendingSaves()
        let container = try Vault.seal(newUnlocked)
        // Prove the bytes reopen with the key we hold before they replace a
        // working vault. This is a self-consistency check, not a policy gate:
        // we already possess the DEK here, so there is nothing to enforce.
        try Vault.validate(container: container, dek: newUnlocked.dek)
        try await store.write(container)
        unlocked = newUnlocked
        onPersist(container, newUnlocked)
    }

    // MARK: - Reveal authorization

    private var lastRevealAuthorization: Date?

    /// Enforces the "require authentication to reveal" setting using system
    /// authentication (Touch ID or the login password).
    func authorizeReveal() async -> Bool {
        switch settings.revealPolicy {
        case .never:
            return true
        case .afterMinutes(let minutes):
            if let last = lastRevealAuthorization,
               Date().timeIntervalSince(last) < Double(minutes) * 60 {
                return true
            }
        case .everyTime:
            break
        }
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "reveal a stored secret"
            )
            if success { lastRevealAuthorization = Date() }
            return success
        } catch {
            return false
        }
    }

    var dek: SymmetricKey { unlocked.dek }

    /// Serializes saves. Detached tasks could otherwise complete out of order
    /// and leave a stale container as the last thing written; chaining each
    /// save onto the previous one keeps disk order equal to edit order.
    private var pendingSave: Task<Void, Never>?

    private func persist() {
        let snapshot = unlocked
        do {
            let container = try Vault.seal(snapshot)
            let previous = pendingSave
            pendingSave = Task { [store, onPersist] in
                await previous?.value
                do {
                    try await store.write(container)
                    onPersist(container, snapshot)
                } catch {
                    self.saveError = "Could not save the vault: \(error.localizedDescription)"
                }
            }
        } catch {
            saveError = "Could not encrypt the vault: \(error.localizedDescription)"
        }
    }

    /// Waits for any in-flight save. Callers that are about to re-wrap the
    /// vault (password or policy change) use this so their read-modify-write
    /// cannot race an outstanding write.
    func flushPendingSaves() async {
        await pendingSave?.value
    }
}
