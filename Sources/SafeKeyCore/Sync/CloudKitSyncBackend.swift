import Foundation
import CloudKit

/// The CloudKit half of sync.
///
/// Every wallet is one record in the user's **private** database, holding the
/// sealed bytes and nothing else readable. CloudKit sees an opaque blob, a
/// modification date and a vault id — never a name, a chain, or a secret.
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

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let vaultID: UUID
    private var zoneEnsured = false

    /// Vault ids seen on records we could not open, so the app can tell the
    /// user "this iCloud account holds a different vault" rather than silently
    /// syncing nothing.
    public private(set) var foreignVaultIDs: Set<UUID> = []

    public init(vaultID: UUID, containerIdentifier: String = CloudKitSyncBackend.containerIdentifier) {
        self.database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.vaultID = vaultID
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
    private func withZone<T>(_ operation: () async throws -> T) async throws -> T {
        try await ensureZone()
        do {
            return try await operation()
        } catch let error as CKError where Self.zoneIsGone(error) {
            zoneEnsured = false
            try await ensureZone()
            return try await operation()
        }
    }

    private static func zoneIsGone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
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
                if record.recordType == Self.vaultRecordType { continue }
                guard let payload = record["payload"] as? Data,
                      let modifiedAt = record["modifiedAt"] as? Date
                else { continue }

                if let recordVault = record["vaultID"] as? String,
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
        try await withZone {
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
        try await withZone {
            let id = CKRecord.ID(recordName: Self.vaultRecordName, zoneID: zoneID)
            let record = CKRecord(recordType: Self.vaultRecordType, recordID: id)
            record["header"] = vault.header as CKRecordValue
            record["vaultID"] = vault.vaultID.uuidString as CKRecordValue
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        }
    }

    public func save(_ records: [SyncRecord]) async throws {
        let ckRecords = records.map { record -> CKRecord in
            let id = CKRecord.ID(recordName: record.id, zoneID: zoneID)
            let ck = CKRecord(recordType: Self.recordType, recordID: id)
            ck["payload"] = record.payload as CKRecordValue
            ck["modifiedAt"] = record.modifiedAt as CKRecordValue
            ck["vaultID"] = vaultID.uuidString as CKRecordValue
            return ck
        }
        // Last writer wins at the record level; the engine above has already
        // decided which version that should be, and kept the loser.
        try await withZone {
            _ = try await database.modifyRecords(saving: ckRecords, deleting: [], savePolicy: .allKeys)
        }
    }

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let recordIDs = ids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            try await withZone {
                _ = try await database.modifyRecords(saving: [], deleting: recordIDs)
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
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Nothing there to remove is the desired end state, not a failure.
        }
        zoneEnsured = false
        foreignVaultIDs = []
    }
}
