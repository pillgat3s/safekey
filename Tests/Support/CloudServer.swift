import Foundation
import CryptoKit
@testable import SafeKeyCore

/// One shared zone, talked to by several devices — the shape CloudKit gives us.
///
/// Deliberately more demanding than a per-device fake: both devices address the
/// same records, each device's own writes come back to it in its own change
/// feed (CloudKit does that, and mishandling it makes every quiet sync rewrite
/// the vault), deletions leave tombstones only for devices that were already
/// caught up, and wiping the zone invalidates outstanding tokens the way
/// `changeTokenExpired` does.
actor CloudServer {
    private struct Slot {
        /// nil once deleted — the slot stays as a tombstone.
        var record: SyncRecord?
        var version: Int
    }

    private var slots: [String: Slot] = [:]
    private var clock = 0
    private var vault: SyncedVault?
    /// Bumped when the zone is wiped, so tokens issued before it are refused.
    private var generation = 0

    func save(_ records: [SyncRecord]) {
        for record in records {
            clock += 1
            slots[record.id] = Slot(record: record, version: clock)
        }
    }

    func delete(ids: [String]) {
        for id in ids {
            clock += 1
            slots[id] = Slot(record: nil, version: clock)
        }
    }

    func changes(since token: Data?) -> SyncChanges {
        let position = parse(token)
        // A device with no usable token gets the live records and no
        // tombstones, exactly as a first fetch from a real zone does.
        guard let position else {
            return SyncChanges(
                records: slots.values.compactMap(\.record),
                deletedIDs: [],
                token: currentToken,
                isFullResync: true
            )
        }
        var records: [SyncRecord] = []
        var deletions: [String] = []
        for (id, slot) in slots where slot.version > position {
            if let record = slot.record { records.append(record) } else { deletions.append(id) }
        }
        return SyncChanges(records: records, deletedIDs: deletions, token: currentToken)
    }

    func fetchVault() -> SyncedVault? { vault }
    func saveVault(_ vault: SyncedVault) { self.vault = vault }

    /// Records belonging to a vault this device cannot open. The real backend
    /// works these out from a field on the record; here they are simply told.
    private(set) var foreignVaultIDs: Set<UUID> = []
    func markForeign(_ id: UUID) { foreignVaultIDs.insert(id) }

    /// One record as the zone currently holds it, for assertions.
    func record(for id: String) -> SyncRecord? { slots[id]?.record }

    /// Everything the zone currently holds, for assertions.
    var liveRecordIDs: Set<String> { Set(slots.compactMap { $0.value.record == nil ? nil : $0.key }) }

    /// Models the zone being deleted and recreated — what `Replace` does, and
    /// what leaves the other device holding a token the server no longer knows.
    func wipeZone() {
        slots.removeAll()
        vault = nil
        generation += 1
        clock = 0
    }

    private var currentToken: Data { Data("\(generation):\(clock)".utf8) }

    /// Returns nil for "start from scratch": no token, or one from a
    /// generation this zone no longer has.
    private func parse(_ token: Data?) -> Int? {
        guard let token,
              let parts = String(decoding: token, as: UTF8.self).split(separator: ":") as [Substring]?,
              parts.count == 2,
              let tokenGeneration = Int(parts[0]),
              let position = Int(parts[1]),
              tokenGeneration == generation
        else { return nil }
        return position
    }
}

/// One device's connection to the shared zone.
struct DeviceBackend: CloudBackend {
    let server: CloudServer

    var foreignVaultIDs: Set<UUID> { get async { await server.foreignVaultIDs } }
    func removeEverything() async throws { await server.wipeZone() }

    func fetchChanges(since token: Data?) async throws -> SyncChanges { await server.changes(since: token) }
    func save(_ records: [SyncRecord]) async throws { await server.save(records) }
    func delete(ids: [String]) async throws { await server.delete(ids: ids) }
    func fetchVault() async throws -> SyncedVault? { await server.fetchVault() }
    func saveVault(_ vault: SyncedVault) async throws { await server.saveVault(vault) }
}


/// A device: its own copy of the vault, its own bookkeeping, one shared zone.
struct Device {
    var payload: VaultPayload
    var state = VaultSync.State()
    let sync: VaultSync

    init(server: CloudServer, dek: SymmetricKey, payload: VaultPayload = VaultPayload()) {
        self.payload = payload
        self.sync = VaultSync(backend: DeviceBackend(server: server), dek: dek)
    }

    @discardableResult
    mutating func syncNow() async throws -> VaultSync.Outcome {
        try await sync.run(payload: &payload, state: &state)
    }

    /// Quitting and relaunching: the payload and the bookkeeping come back
    /// from disk, in-memory state does not.
    mutating func relaunch() throws {
        let encoded = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(VaultSync.State.self, from: encoded)
    }

    var names: Set<String> { Set(payload.entries.map(\.name)) }
    var groupNames: Set<String> { Set(payload.groups.map(\.name)) }
}


// MARK: - Shared groups

/// Several iCloud accounts, each with its own zones, and the shared groups
/// between them — the shape CloudKit gives a group's owner and its members.
///
/// A group is one `CloudServer` zone owned by one account. Inviting someone
/// puts them on the participant list; once they accept, their `discover`
/// returns the group and their backend talks to the same zone the owner's
/// does. Deleting the zone, or taking a participant off the list, makes the
/// group disappear from that participant's next look.
actor FakeCloud {
    struct Zone {
        let owner: String
        var membership: SharedGroupMembership
        var name: String
        let server: CloudServer
        var participants: Set<String> = []
        var invited: Set<String> = []
    }

    private(set) var zones: [UUID: Zone] = [:]
    /// Every call that reached the cloud, for assertions about what a device
    /// did and did not do.
    private(set) var log: [String] = []

    func createZone(owner: String, membership: SharedGroupMembership, name: String) {
        log.append("create \(owner) \(membership.id)")
        zones[membership.id] = Zone(owner: owner, membership: membership, name: name, server: CloudServer())
    }

    /// What one account can see: its own groups, and the ones it accepted.
    func discover(account: String) -> [SharedGroupMembership] {
        log.append("discover \(account)")
        return zones.values.compactMap { zone in
            if zone.owner == account {
                return SharedGroupMembership(id: zone.membership.id, key: zone.membership.key, isOwner: true)
            }
            if zone.participants.contains(account) {
                return SharedGroupMembership(id: zone.membership.id, key: zone.membership.key, isOwner: false, zoneOwnerName: zone.owner)
            }
            return nil
        }
    }

    func server(for groupID: UUID) -> CloudServer? { zones[groupID]?.server }

    func invite(_ account: String, to groupID: UUID) {
        zones[groupID]?.invited.insert(account)
    }

    /// Accepting an invitation, which is what puts the zone in the member's
    /// shared database.
    func accept(_ account: String, groupID: UUID) throws {
        guard zones[groupID]?.invited.contains(account) == true else {
            throw SyncError.unavailable("\(account) was not invited to \(groupID)")
        }
        zones[groupID]?.invited.remove(account)
        zones[groupID]?.participants.insert(account)
    }

    /// The owner taking someone out of the group.
    func removeParticipant(_ account: String, from groupID: UUID) {
        zones[groupID]?.participants.remove(account)
    }

    func remove(account: String, membership: SharedGroupMembership) {
        log.append("remove \(account) \(membership.id)")
        guard var zone = zones[membership.id] else { return }
        if zone.owner == account {
            zones.removeValue(forKey: membership.id)
        } else {
            zone.participants.remove(account)
            zones[membership.id] = zone
        }
    }

    var groupIDs: Set<UUID> { Set(zones.keys) }
    func participants(of groupID: UUID) -> Set<String> { zones[groupID]?.participants ?? [] }
    func name(of groupID: UUID) -> String? { zones[groupID]?.name }
}

/// Whether a device can reach the cloud, flipped by a test to model going
/// offline and coming back.
actor OnlineSwitch {
    private(set) var isOnline = true
    func set(online: Bool) { isOnline = online }
}

/// One account's view of the shared groups in `FakeCloud`.
struct FakeSharedGroupService: SharedGroupService {
    let cloud: FakeCloud
    let account: String
    /// Every call fails while this says offline.
    let connection: OnlineSwitch?

    init(cloud: FakeCloud, account: String, connection: OnlineSwitch? = nil) {
        self.cloud = cloud
        self.account = account
        self.connection = connection
    }

    private func checkOnline() async throws {
        if let connection, await !connection.isOnline {
            throw SyncError.unavailable("offline")
        }
    }

    func create(_ membership: SharedGroupMembership, name: String) async throws {
        try await checkOnline()
        await cloud.createZone(owner: account, membership: membership, name: name)
    }

    func discover() async throws -> [SharedGroupMembership] {
        try await checkOnline()
        return await cloud.discover(account: account)
    }

    func makeBackend(for membership: SharedGroupMembership) -> any SyncBackend {
        FakeZoneBackend(cloud: cloud, account: account, groupID: membership.id, connection: connection)
    }

    func remove(_ membership: SharedGroupMembership) async throws {
        try await checkOnline()
        await cloud.remove(account: account, membership: membership)
    }
}

/// Reaches a group's zone through the cloud each time, so a zone that has
/// been deleted — or that this account was removed from — fails the way a
/// missing CloudKit zone does rather than carrying on against a copy.
struct FakeZoneBackend: SyncBackend {
    let cloud: FakeCloud
    let account: String
    let groupID: UUID
    let connection: OnlineSwitch?

    private func zone() async throws -> CloudServer {
        if let connection, await !connection.isOnline {
            throw SyncError.unavailable("offline")
        }
        let visible = await cloud.discover(account: account).contains { $0.id == groupID }
        guard visible, let server = await cloud.server(for: groupID) else {
            throw SyncError.unavailable("This shared group no longer exists.")
        }
        return server
    }

    func fetchChanges(since token: Data?) async throws -> SyncChanges { await try zone().changes(since: token) }
    func save(_ records: [SyncRecord]) async throws { await try zone().save(records) }
    func delete(ids: [String]) async throws { await try zone().delete(ids: ids) }
    func fetchVault() async throws -> SyncedVault? { nil }
    func saveVault(_ vault: SyncedVault) async throws {}
}
