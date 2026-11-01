import Foundation
import CloudKit

/// Shared groups in CloudKit: one zone per group, shared as a whole.
///
/// The zone is created in the owner's private database together with two
/// records: a root record carrying the group key in an encrypted field, and
/// the share for the zone. Inviting someone hands them the share; accepting
/// it puts the zone in their shared database, where the same root record —
/// with the key CloudKit decrypts for them — and the same wallet records are
/// waiting. From then on each member's device syncs the zone the way it syncs
/// the vault's own, under the group key instead of the vault's.
///
/// The key is end to end encrypted twice over: once by CloudKit's encrypted
/// field, whose keys live in the members' iCloud Keychains and never on
/// Apple's servers in the clear, and once more because everything sealed
/// under it is AES-GCM ciphertext before it leaves the device. The name is
/// the one thing in the open — it is on the invitation, where the invitee has
/// to be able to read it.
public actor CloudKitSharedGroupService: SharedGroupService {
    public static let zonePrefix = "sg-"
    static let rootRecordType = "SharedGroup"
    static let rootRecordName = "root"
    static let keyField = "key"
    static let groupIDField = "groupID"

    public nonisolated let container: CKContainer

    public init(containerIdentifier: String = CloudKitSyncBackend.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public static func zoneName(for groupID: UUID) -> String {
        zonePrefix + groupID.uuidString
    }

    public static func groupID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(zonePrefix.count)))
    }

    /// Where this account reaches the group's zone.
    nonisolated func zoneID(for membership: SharedGroupMembership) -> CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: Self.zoneName(for: membership.id),
            ownerName: membership.zoneOwnerName ?? CKCurrentUserDefaultName
        )
    }

    nonisolated func database(for membership: SharedGroupMembership) -> CKDatabase {
        membership.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private nonisolated func shareRecordID(for membership: SharedGroupMembership) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: membership))
    }

    // MARK: - SharedGroupService

    public func create(_ membership: SharedGroupMembership, name: String) async throws {
        let database = container.privateCloudDatabase
        let zoneID = zoneID(for: membership)
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

        let root = CKRecord(
            recordType: Self.rootRecordType,
            recordID: CKRecord.ID(recordName: Self.rootRecordName, zoneID: zoneID)
        )
        root.encryptedValues[Self.keyField] = membership.key
        root[Self.groupIDField] = membership.id.uuidString as CKRecordValue

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = name as CKRecordValue
        share.publicPermission = .none

        // Together, so a zone never exists without its key and its share:
        // the two are what make it a shared group rather than a stray zone.
        _ = try await database.modifyRecords(saving: [root, share], deleting: [], savePolicy: .allKeys)
    }

    public func discover() async throws -> [SharedGroupMembership] {
        var found: [SharedGroupMembership] = []
        let owned = try await container.privateCloudDatabase.allRecordZones()
        for zone in owned where Self.groupID(fromZoneName: zone.zoneID.zoneName) != nil {
            if let membership = try await membership(in: zone.zoneID, database: container.privateCloudDatabase, isOwner: true) {
                found.append(membership)
            }
        }
        let joined = try await container.sharedCloudDatabase.allRecordZones()
        for zone in joined where Self.groupID(fromZoneName: zone.zoneID.zoneName) != nil {
            if let membership = try await membership(in: zone.zoneID, database: container.sharedCloudDatabase, isOwner: false) {
                found.append(membership)
            }
        }
        return found
    }

    /// Reads a zone's root record for the key. A zone with the right name but
    /// no root is not a group — left over from a failed creation, say — and is
    /// skipped rather than reported.
    private func membership(in zoneID: CKRecordZone.ID, database: CKDatabase, isOwner: Bool) async throws -> SharedGroupMembership? {
        let id = CKRecord.ID(recordName: Self.rootRecordName, zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            guard let key = record.encryptedValues[Self.keyField] as? Data,
                  key.count == 32,
                  let raw = record[Self.groupIDField] as? String,
                  let groupID = UUID(uuidString: raw)
            else { return nil }
            return SharedGroupMembership(
                id: groupID,
                key: key,
                isOwner: isOwner,
                zoneOwnerName: isOwner ? nil : zoneID.ownerName
            )
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    public nonisolated func makeBackend(for membership: SharedGroupMembership) -> any SyncBackend {
        CloudKitSyncBackend(
            sharedGroup: membership.id,
            zoneID: zoneID(for: membership),
            database: database(for: membership)
        )
    }

    public func remove(_ membership: SharedGroupMembership) async throws {
        if membership.isOwner {
            // The zone goes, and the share with it: every member's shared
            // database stops listing it on their next look.
            do {
                _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID(for: membership)])
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                // Already gone is what was asked for.
            }
        } else {
            // A member leaves by deleting the share from their shared
            // database, which takes them off the participant list without
            // touching the owner's zone.
            do {
                _ = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareRecordID(for: membership)])
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                // Already out.
            }
        }
    }

    // MARK: - Invitations

    /// The share to put in front of the user for inviting and managing
    /// people. For the owner, one is made if the zone has none — "Stop
    /// Sharing" in the system sheet deletes it, and the group should still be
    /// shareable afterwards.
    public func share(for membership: SharedGroupMembership, name: String) async throws -> CKShare {
        let database = database(for: membership)
        do {
            guard let share = try await database.record(for: shareRecordID(for: membership)) as? CKShare else {
                throw SyncError.unavailable("This group's share could not be read.")
            }
            return share
        } catch let error as CKError where error.code == .unknownItem && membership.isOwner {
            let share = CKShare(recordZoneID: zoneID(for: membership))
            share[CKShare.SystemFieldKey.title] = name as CKRecordValue
            share.publicPermission = .none
            let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .allKeys)
            guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else {
                throw SyncError.unavailable("This group's share could not be created.")
            }
            return saved
        }
    }

    /// Joins a group from an invitation. The zone then shows up in the shared
    /// database, where the next discovery picks it up.
    public func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }
}
