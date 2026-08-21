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
public actor CloudKitSyncBackend: SyncBackend {
    public static let containerIdentifier = "iCloud.com.pill.safekey"
    static let zoneName = "SafeKeyVault"
    static let recordType = "Wallet"

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

        // The server pages; keep going so one run reaches a consistent point
        // rather than leaving half the changes for next time.
        while more {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor)
            for modification in result.modificationResultsByID.values {
                guard let record = try? modification.get().record else { continue }
                guard let payload = record[Self.recordType] as? Data ?? record["payload"] as? Data,
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
        return SyncChanges(records: records, deletedIDs: deletions, token: encoded)
    }

    public func save(_ records: [SyncRecord]) async throws {
        try await ensureZone()
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
        _ = try await database.modifyRecords(saving: ckRecords, deleting: [], savePolicy: .allKeys)
    }

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await ensureZone()
        let recordIDs = ids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        _ = try await database.modifyRecords(saving: [], deleting: recordIDs)
    }

    /// Removes everything this vault has in iCloud — used when the user turns
    /// sync off and asks for the copy to be cleared.
    public func removeEverything() async throws {
        _ = try? await database.modifyRecordZones(saving: [], deleting: [zoneID])
        zoneEnsured = false
    }
}
