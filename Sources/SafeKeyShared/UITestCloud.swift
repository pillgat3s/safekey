#if DEBUG
import Foundation
import SafeKeyCore

/// An iCloud that lives inside the process, for UI tests and screenshots.
///
/// `--uitest-fakecloud` gives the app this instead of CloudKit, so the whole
/// shared-group flow — creating, moving wallets in, managing, deleting — can
/// be driven on a simulator with no Apple ID. One account, which owns every
/// group it makes; inviting people needs the real thing.
actor UITestCloud {
    private struct Zone {
        var records: [String: (record: SyncRecord?, version: Int)] = [:]
        var clock = 0
        var vault: SyncedVault?

        mutating func save(_ records: [SyncRecord]) {
            for record in records {
                clock += 1
                self.records[record.id] = (record, clock)
            }
        }

        mutating func delete(_ ids: [String]) {
            for id in ids {
                clock += 1
                records[id] = (nil, clock)
            }
        }

        func changes(since token: Data?) -> SyncChanges {
            let position = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
            let current = Data(String(clock).utf8)
            guard let position else {
                return SyncChanges(records: records.values.compactMap(\.record), deletedIDs: [], token: current, isFullResync: true)
            }
            var changed: [SyncRecord] = []
            var deleted: [String] = []
            for (id, slot) in records where slot.version > position {
                if let record = slot.record { changed.append(record) } else { deleted.append(id) }
            }
            return SyncChanges(records: changed, deletedIDs: deleted, token: current)
        }
    }

    private var vaultZone = Zone()
    private var groups: [UUID: (membership: SharedGroupMembership, zone: Zone)] = [:]

    func create(_ membership: SharedGroupMembership) {
        groups[membership.id] = (membership, Zone())
    }

    func discover() -> [SharedGroupMembership] {
        groups.values.map(\.membership)
    }

    func remove(_ id: UUID) {
        groups.removeValue(forKey: id)
    }

    func changes(group: UUID?, since token: Data?) throws -> SyncChanges {
        guard let group else { return vaultZone.changes(since: token) }
        guard let zone = groups[group]?.zone else { throw SyncError.unavailable("This shared group no longer exists.") }
        return zone.changes(since: token)
    }

    func save(group: UUID?, _ records: [SyncRecord]) throws {
        guard let group else { return vaultZone.save(records) }
        guard groups[group] != nil else { throw SyncError.unavailable("This shared group no longer exists.") }
        groups[group]!.zone.save(records)
    }

    func delete(group: UUID?, _ ids: [String]) throws {
        guard let group else { return vaultZone.delete(ids) }
        guard groups[group] != nil else { throw SyncError.unavailable("This shared group no longer exists.") }
        groups[group]!.zone.delete(ids)
    }

    func fetchVault() -> SyncedVault? { vaultZone.vault }
    func saveVault(_ vault: SyncedVault) { vaultZone.vault = vault }
    func wipeVaultZone() { vaultZone = Zone() }
}

struct UITestCloudBackend: CloudBackend {
    let cloud: UITestCloud
    let group: UUID?

    var foreignVaultIDs: Set<UUID> { [] }
    func removeEverything() async throws { await cloud.wipeVaultZone() }
    func fetchChanges(since token: Data?) async throws -> SyncChanges { try await cloud.changes(group: group, since: token) }
    func save(_ records: [SyncRecord]) async throws { try await cloud.save(group: group, records) }
    func delete(ids: [String]) async throws { try await cloud.delete(group: group, ids) }
    func fetchVault() async throws -> SyncedVault? { await cloud.fetchVault() }
    func saveVault(_ vault: SyncedVault) async throws { await cloud.saveVault(vault) }
}

struct UITestSharedGroupService: SharedGroupService {
    let cloud: UITestCloud

    func create(_ membership: SharedGroupMembership, name: String) async throws { await cloud.create(membership) }
    func discover() async throws -> [SharedGroupMembership] { await cloud.discover() }
    func makeBackend(for membership: SharedGroupMembership) -> any SyncBackend {
        UITestCloudBackend(cloud: cloud, group: membership.id)
    }
    func remove(_ membership: SharedGroupMembership) async throws { await cloud.remove(membership.id) }
}

extension SyncCoordinator.Environment {
    /// The in-process iCloud, for `--uitest-fakecloud`.
    static func uiTestFake() -> SyncCoordinator.Environment {
        let cloud = UITestCloud()
        return SyncCoordinator.Environment(
            isAvailable: { true },
            makeBackend: { _ in UITestCloudBackend(cloud: cloud, group: nil) },
            sharing: UITestSharedGroupService(cloud: cloud),
            editDebounce: .milliseconds(300)
        )
    }
}
#endif
