import Foundation

/// Splits the vault into the pieces that live in different iCloud zones.
///
/// A vault is one file on disk, but in iCloud it is several zones: the
/// account's private zone for the wallets that are nobody else's business,
/// and one zone per shared group, sealed under that group's own key and
/// shared with its members. The merge engine works on one zone at a time, so
/// before each zone's run the vault is cut down to that zone's share of it,
/// and afterwards the merged piece is folded back in.
///
/// Membership decides the cut: a wallet whose group is shared belongs to that
/// group's zone, everything else to the private one. Which is also why a move
/// between a private group and a shared one is a deletion in one zone and an
/// addition in the other, rather than an edit.
public enum SharedGroupPartition {
    /// What a member's device calls a group whose record has not arrived yet.
    /// Replaced by the owner's record on the next sync, which is always newer.
    public static let placeholderName = "Shared Group"

    public static func sharedGroupIDs(in payload: VaultPayload) -> Set<UUID> {
        Set(payload.sharedGroups.map(\.id))
    }

    /// Whether a wallet lives in a shared group's zone rather than the private one.
    public static func isShared(_ entry: WalletEntry, in payload: VaultPayload) -> Bool {
        guard let groupID = entry.groupID else { return false }
        return payload.sharedGroups.contains { $0.id == groupID }
    }

    /// The private zone's share of the vault: every wallet and group that is
    /// not in a shared group.
    public static func privatePart(of payload: VaultPayload) -> VaultPayload {
        let shared = sharedGroupIDs(in: payload)
        var part = VaultPayload()
        part.entries = payload.entries.filter { entry in
            entry.groupID.map { !shared.contains($0) } ?? true
        }
        part.groups = payload.groups.filter { !shared.contains($0.id) }
        return part
    }

    /// One shared group's share of the vault: its wallets, and the group
    /// itself. The group is always present — a stand-in goes in when the real
    /// record has not arrived — because the merge clears the group of any
    /// wallet whose group it cannot see, and that would push the whole zone's
    /// wallets into the private one.
    public static func groupPart(of payload: VaultPayload, group id: UUID) -> VaultPayload {
        var part = VaultPayload()
        part.entries = payload.entries.filter { $0.groupID == id }
        part.groups = [payload.groups.first { $0.id == id } ?? placeholder(id)]
        return part
    }

    public static func placeholder(_ id: UUID) -> WalletGroup {
        WalletGroup(id: id, name: placeholderName, chain: .evm, modifiedAt: .distantPast)
    }

    public static func isPlaceholder(_ group: WalletGroup) -> Bool {
        group.name == placeholderName && group.modifiedAt == .distantPast
    }

    /// Folds the private zone's merged piece back into the vault, leaving the
    /// shared groups' wallets exactly as they were.
    ///
    /// A wallet the private zone hands back under an id that a shared group
    /// already holds is the stale private copy of a wallet another device
    /// moved into the group — the group's copy is the live one and wins. The
    /// private record goes away when that device's deletion lands.
    public static func adoptPrivate(_ merged: VaultPayload, into payload: inout VaultPayload) {
        let shared = sharedGroupIDs(in: payload)
        let sharedEntries = payload.entries.filter { entry in
            entry.groupID.map { shared.contains($0) } ?? false
        }
        let sharedEntryIDs = Set(sharedEntries.map(\.id))
        payload.entries = sharedEntries + merged.entries.filter { !sharedEntryIDs.contains($0.id) }
        let sharedGroups = payload.groups.filter { shared.contains($0.id) }
        payload.groups = sharedGroups + merged.groups.filter { !shared.contains($0.id) }
    }

    /// Folds one shared group's merged piece back into the vault.
    ///
    /// Everything the zone holds replaces what the vault held for that group:
    /// a wallet missing from the piece was deleted in the zone and goes; a
    /// wallet the piece carries under an id found elsewhere in the vault was
    /// moved into the group by another device, and the group's copy wins.
    public static func adoptGroup(_ merged: VaultPayload, group id: UUID, into payload: inout VaultPayload) {
        let incoming = Set(merged.entries.map(\.id))
        payload.entries.removeAll { $0.groupID == id || incoming.contains($0.id) }
        payload.entries += merged.entries.map { entry in
            var entry = entry
            entry.groupID = id
            return entry
        }
        if let group = merged.groups.first(where: { $0.id == id }) {
            if let index = payload.groups.firstIndex(where: { $0.id == id }) {
                payload.groups[index] = group
            } else {
                payload.groups.append(group)
            }
        }
    }

    /// Takes a shared group out of the vault.
    ///
    /// The owner keeps the wallets — they move to the private part of the
    /// vault, which is where they were before the group. A member does not:
    /// the owner deleted the group or took the member out of it, and the
    /// wallets were never the member's own.
    public static func removeSharedGroup(id: UUID, from payload: inout VaultPayload, keepingWallets: Bool) {
        payload.sharedGroups.removeAll { $0.id == id }
        payload.groups.removeAll { $0.id == id }
        if keepingWallets {
            for index in payload.entries.indices where payload.entries[index].groupID == id {
                payload.entries[index].groupID = nil
                payload.entries[index].modifiedAt = .vaultNow()
            }
        } else {
            payload.entries.removeAll { $0.groupID == id }
        }
    }
}
