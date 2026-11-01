import Foundation
import CloudKit

/// The CloudKit half of sync.
///
/// Every wallet is one record in a zone the user controls, holding the sealed
/// bytes and nothing else readable. CloudKit sees an opaque blob, a
/// modification date and an owner id — never a name, a chain, or a secret.
///
/// Two kinds of zone, one class. The vault's own zone lives in the **private**
/// database and carries the wallets that are nobody else's business. A shared
/// group's zone lives in its owner's private database too, but shared with
/// the group's members, who reach it through their **shared** database; its
/// records are sealed under the group's key rather than the vault's.
///
/// A custom zone rather than the default one: only a custom zone supports the
/// change tokens and deletion tracking that make an incremental sync possible.
/// Without deletion tracking, a wallet deleted on one device would be restored
/// by the other on the next run.
public actor CloudKitSyncBackend: CloudBackend {
    public static let containerIdentifier = "iCloud.com.pill.safekey"
    static let zoneName = "SafeKeyVault"
    static let recordType = "Wallet"
    static let vaultRecordType = "Vault"
    /// One vault record per zone, at a fixed name, so both devices address the
    /// same record rather than each creating its own.
    static let vaultRecordName = "vault"

    /// Whose records a zone holds, and so which records this device is to
    /// take and which to leave alone.
    enum Scope: Sendable {
        /// The vault's zone. Records carry the vault id; one from another
        /// vault is reported as foreign rather than opened.
        case vault(UUID)
        /// A shared group's zone. Records carry the group id. The zone is the
        /// owner's to create and delete, so it is never created here.
        case sharedGroup(UUID)
    }

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let scope: Scope
    private var zoneEnsured = false

    /// Vault ids seen on records we could not open, so the app can tell the
    /// user "this iCloud account holds a different vault" rather than silently
    /// syncing nothing.
    public private(set) var foreignVaultIDs: Set<UUID> = []

    public init(vaultID: UUID, containerIdentifier: String = CloudKitSyncBackend.containerIdentifier) {
        self.database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.scope = .vault(vaultID)
    }

    /// A backend for one shared group's zone, in whichever database this
    /// account reaches it through.
    init(sharedGroup groupID: UUID, zoneID: CKRecordZone.ID, database: CKDatabase) {
        self.database = database
        self.zoneID = zoneID
        self.scope = .sharedGroup(groupID)
        // Somebody else's zone, or this account's own but made elsewhere;
        // either way it exists already or the group does not.
        self.zoneEnsured = true
    }

    /// Whether this device can sync at all: an iCloud account has to be signed
    /// in, and the container has to be reachable.
    public static func isAvailable(containerIdentifier: String = CloudKitSyncBackend.containerIdentifier) async -> Bool {
        do {
            return try await CKContainer(identifier: containerIdentifier).accountStatus() == .available
        } catch {
            return false
        }
    }

    private func ensureZone() async throws {
        guard !zoneEnsured else { return }
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            zoneEnsured = true
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already there, created by the other device.
            zoneEnsured = true
        }
    }

    /// Runs an operation, and if the server says the zone is gone, recreates it
    /// and tries once more.
    ///
    /// The zone can disappear underneath a running app: replacing the iCloud
    /// copy on the other device deletes it. Without this, the first failure
    /// would stick — we remember having created the zone, so every later call
    /// would go straight to a zone that is no longer there.
    ///
    /// A shared group's zone is not recreated: it is the owner's, and its
    /// absence means the group is gone. The error goes up, and the next
    /// discovery takes the group out of the vault.
    private func withZone<T>(_ operation: () async throws -> T) async throws -> T {
        try await ensureZone()
        do {
            return try await operation()
        } catch let error as CKError where Self.zoneIsGone(error) {
            guard case .vault = scope else { throw SyncError.unavailable("This shared group no longer exists.") }
            zoneEnsured = false
            try await ensureZone()
            return try await operation()
        }
    }

    private static func zoneIsGone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    /// The field that names whose record this is, and the value it carries.
    private var ownerField: (key: String, value: String) {
        switch scope {
        case .vault(let vaultID): ("vaultID", vaultID.uuidString)
        case .sharedGroup(let groupID): ("groupID", groupID.uuidString)
        }
    }

    // MARK: - SyncBackend

    public func fetchChanges(since token: Data?) async throws -> SyncChanges {
        try await ensureZone()

        let serverToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }

        var records: [SyncRecord] = []
        var deletions: [String] = []
        var cursor = serverToken
        var more = true
        // Either we had no resume point, or the server refused the one we had
        // below. Both mean the answer describes the whole zone rather than
        // what changed, and the caller has to treat its bookkeeping as stale.
        var fromScratch = serverToken == nil

        // The server pages; keep going so one run reaches a consistent point
        // rather than leaving half the changes for next time.
        while more {
            let result: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                result = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor)
            } catch let error as CKError where error.code == .changeTokenExpired || Self.zoneIsGone(error) {
                // The token points at a zone state the server no longer has —
                // typically because the zone was deleted and recreated by
                // another device. Start over from nothing rather than failing
                // on every sync from here on.
                if Self.zoneIsGone(error) {
                    guard case .vault = scope else {
                        throw SyncError.unavailable("This shared group no longer exists.")
                    }
                    zoneEnsured = false
                    try await ensureZone()
                }
                cursor = nil
                records.removeAll()
                deletions.removeAll()
                fromScratch = true
                result = try await database.recordZoneChanges(inZoneWith: zoneID, since: nil)
            }
            for modification in result.modificationResultsByID.values {
                guard let record = try? modification.get().record else { continue }
                // Only wallet records are the engine's to merge. The vault
                // record, a shared group's root record and the share itself
                // live in the same zone and are read elsewhere.
                guard record.recordType == Self.recordType else { continue }
                guard let payload = record["payload"] as? Data,
                      let modifiedAt = record["modifiedAt"] as? Date
                else { continue }

                if case .vault(let vaultID) = scope,
                   let recordVault = record["vaultID"] as? String,
                   let parsed = UUID(uuidString: recordVault),
                   parsed != vaultID {
                    foreignVaultIDs.insert(parsed)
                    continue
                }
                records.append(SyncRecord(
                    id: record.recordID.recordName,
                    payload: payload,
                    modifiedAt: modifiedAt
                ))
            }
            deletions.append(contentsOf: result.deletions.map(\.recordID.recordName))
            cursor = result.changeToken
            more = result.moreComing
        }

        let encoded = cursor.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return SyncChanges(
            records: records,
            deletedIDs: deletions,
            token: encoded,
            isFullResync: fromScratch
        )
    }

    public func fetchVault() async throws -> SyncedVault? {
        guard case .vault = scope else { return nil }
        return try await withZone {
            let id = CKRecord.ID(recordName: Self.vaultRecordName, zoneID: zoneID)
            do {
                let record = try await database.record(for: id)
                guard let header = record["header"] as? Data,
                      let raw = record["vaultID"] as? String,
                      let uuid = UUID(uuidString: raw)
                else { return nil }
                return SyncedVault(vaultID: uuid, header: header)
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    public func saveVault(_ vault: SyncedVault) async throws {
        // A shared group's zone carries no vault: the members' vaults are
        // their own, and only the group's wallets are shared.
        guard case .vault = scope else { return }
        try await withZone {
            let id = CKRecord.ID(recordName: Self.vaultRecordName, zoneID: zoneID)
            let record = CKRecord(recordType: Self.vaultRecordType, recordID: id)
            record["header"] = vault.header as CKRecordValue
            record["vaultID"] = vault.vaultID.uuidString as CKRecordValue
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        }
    }

    /// CloudKit refuses a modify request past a few hundred items. A vault
    /// with more wallets than that would fail its first sync outright — and
    /// again after any zone reset, which re-sends everything — so requests go
    /// up in batches. Kept well under the limit rather than at it.
    static let batchLimit = 300

    static func batches<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: batchLimit).map {
            Array(items[$0..<min($0 + batchLimit, items.count)])
        }
    }

    public func save(_ records: [SyncRecord]) async throws {
        let owner = ownerField
        let ckRecords = records.map { record -> CKRecord in
            let id = CKRecord.ID(recordName: record.id, zoneID: zoneID)
            let ck = CKRecord(recordType: Self.recordType, recordID: id)
            ck["payload"] = record.payload as CKRecordValue
            ck["modifiedAt"] = record.modifiedAt as CKRecordValue
            ck[owner.key] = owner.value as CKRecordValue
            return ck
        }
        // Last writer wins at the record level; the engine above has already
        // decided which version that should be, and kept the loser.
        for batch in Self.batches(ckRecords) {
            try await withZone {
                _ = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys)
            }
        }
    }

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let recordIDs = ids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            for batch in Self.batches(recordIDs) {
                try await withZone {
                    _ = try await database.modifyRecords(saving: [], deleting: batch)
                }
            }
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone is the outcome we wanted. Deletions are re-sent
            // until they are confirmed, so meeting one that has already landed
            // is normal rather than a failure.
        }
    }

    /// Removes everything this vault has in iCloud — used when the user turns
    /// sync off and asks for the copy to be cleared.
    public func removeEverything() async throws {
        guard case .vault = scope else { return }
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Nothing there to remove is the desired end state, not a failure.
        }
        zoneEnsured = false
        foreignVaultIDs = []
    }
}
