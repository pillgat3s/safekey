import Foundation
import CryptoKit

/// This device's standing in a shared group: the key the group's wallets
/// travel under, and whether this iCloud account owns the group.
///
/// Kept in the vault rather than fetched each time, so a member can open the
/// group's records the moment they arrive and seal its own edits without a
/// round trip for the key. It is never sent anywhere by sync: the private zone
/// carries wallets and groups one record at a time, and a membership is
/// neither. iCloud holds the key once, inside the group's zone, in a field
/// CloudKit encrypts end to end for the people the zone is shared with.
public struct SharedGroupMembership: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The group's id — the same on every member's device, which is what lets
    /// a wallet carry the group it belongs to across accounts.
    public var id: UUID
    /// The 256-bit key the group's wallets are sealed under in iCloud. Not the
    /// vault's data key: that one is the owner's alone, and handing it out
    /// would open the owner's whole vault to every member.
    public var key: Data
    /// Whether this iCloud account created the group. Only the owner adds or
    /// removes people, renames the group, or deletes it — everyone in it can
    /// add, edit and move wallets.
    public var isOwner: Bool
    /// For a group someone else owns, the CloudKit name of their account,
    /// which is part of the zone's address. Nil for a group this account owns.
    public var zoneOwnerName: String?

    public init(id: UUID = UUID(), key: Data, isOwner: Bool, zoneOwnerName: String? = nil) {
        self.id = id
        self.key = key
        self.isOwner = isOwner
        self.zoneOwnerName = zoneOwnerName
    }

    /// A fresh group key.
    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}
