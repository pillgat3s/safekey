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

