import Foundation
import CloudKit
import SafeKeyCore

/// Drives sync for an unlocked vault: holds the engine, the persisted state,
/// and the status the UI shows.
///
/// Only ever runs while the vault is unlocked, because merging needs the data
/// key. A locked app syncs nothing — there is nothing it could read.
///
/// One run covers every zone the vault spans: the vault's own, where the
/// private wallets go, and one per shared group, each sealed under that
/// group's key and shared with its members. The zones are independent — a
/// group keeps syncing when the vault's own sync is off, because the people
/// in it are waiting on it — and they are run one after another so the vault
/// file is read and written in one place.
@MainActor
@Observable
final class SyncCoordinator {
    enum Status: Equatable, Sendable {
        case off
        case unavailable(String)
        case idle(lastSynced: Date?)
        case syncing
        case failed(String)
        /// The iCloud account holds a vault this device cannot open. Not an
        /// error to retry — the user has to decide which vault to keep.
        case differentVault
    }

    /// How the coordinator reaches iCloud. Everything it needs from CloudKit
    /// is behind this, so the orchestration around it — what gets merged, what
    /// gets written back, what is remembered across a run — can be exercised
    /// without an Apple ID.
    struct Environment: Sendable {
        var isAvailable: @Sendable () async -> Bool
        var makeBackend: @Sendable (UUID) -> any CloudBackend
        /// The shared groups in the account.
        var sharing: any SharedGroupService
        /// How long a change waits for company before it is synced. Editing a
        /// wallet writes more than once, and each write asks for a run.
        var editDebounce: Duration = .seconds(2)

        static let cloudKit = Environment(
            isAvailable: { await CloudKitSyncBackend.isAvailable() },
            makeBackend: { CloudKitSyncBackend(vaultID: $0) },
            sharing: CloudKitSharedGroupService()
        )
    }

    /// Set — in the defaults rather than beside the vault, so it can be set
    /// while the vault is locked — when an invitation was accepted and the
    /// next run has to look for the group it joined.
    static let discoveryPendingKey = "sync.discoveryPending"

    private(set) var status: Status = .off
    private let store: VaultStore
    private let environment: Environment
    private var backend: (any CloudBackend)?
    private var backendVaultID: UUID?
    /// Backends for the shared groups' zones, kept so a change token is not
    /// re-derived from scratch each run.
    private var groupBackends: [UUID: any SyncBackend] = [:]
    private var bookkeeping = Bookkeeping()
    private var loadedStateFor: UUID?
    /// Runs are chained rather than allowed to overlap. Two at once would both
    /// push, and whichever finished second would write back a merge made
    /// against a payload from before the first one landed.
    private var queue: Task<Void, Never>?
    /// Set when the user has decided this vault takes over the iCloud copy, so
    /// the next run is allowed to publish its header over another vault's.
    private var claimCloudVaultOnNextSync = false
    /// The pending post-edit sync, cancelled and re-armed by each new edit.
    private var debounce: Task<Void, Never>?

    var sharing: any SharedGroupService { environment.sharing }

    init(store: VaultStore, environment: Environment = .cloudKit) {
        self.store = store
        self.environment = environment
    }

    /// Syncs if the vault has it switched on. Safe to call often — it returns
    /// immediately when sync is off, and never throws into the caller: a sync
    /// problem must not interrupt using the vault.
    @discardableResult
    func syncIfEnabled(session: VaultSession) async -> VaultSync.Outcome? {
        let previous = queue
        let run = Task { [weak self] () -> VaultSync.Outcome? in
            await previous?.value
            guard let self else { return nil }
            return await self.performSync(session: session)
        }
        queue = Task { _ = await run.value }
        return await run.value
    }

    /// Hooks a freshly unlocked session up to sync.
    ///
    /// In one place rather than at each screen that changes something: a view
    /// that forgot to report a deletion would leave the wallet alive on the
    /// other device, with nothing to show that it had gone.
    func attach(to session: VaultSession) {
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            switch event {
            case .walletDeleted(let id, let groupID):
                self.noteDeletion(walletID: id, inGroup: groupID, session: session)
            case .groupDeleted(let id):
                self.noteDeletion(groupID: id, session: session)
            case .walletMoved(let id, let from, _):
                // Gone from where it was; the run adds it where it is.
                self.noteDeletion(walletID: id, inGroup: from, session: session)
            case .sharedGroupRemoved(let membership):
                self.noteRemoval(of: membership, session: session)
            }
        }
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.scheduleSync(session: session)
        }
    }

    /// Asks for a sync shortly after a change, coalescing a burst into one.
    ///
    /// Called for every write to the vault, which is what makes a rename or a
    /// regrouping travel: syncing only on unlock would leave every edit sitting
    /// on the device that made it until the app was next opened. The delay is
    /// there because editing a wallet writes more than once.
    func scheduleSync(session: VaultSession) {
        guard wantsSync(session) else { return }
        let delay = environment.editDebounce
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncIfEnabled(session: session)
        }
    }

    /// Whether anything about this vault reaches iCloud: its own sync, or a
    /// shared group it belongs to.
    private func wantsSync(_ session: VaultSession) -> Bool {
        session.settings.cloudSyncEnabled || !session.memberships.isEmpty || discoveryPending
    }

    private var discoveryPending: Bool {
        get { UserDefaults.standard.bool(forKey: Self.discoveryPendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.discoveryPendingKey) }
    }

    /// An invitation was accepted: the next run looks for the group.
    func requestDiscovery() {
        discoveryPending = true
    }

    private func performSync(session: VaultSession) async -> VaultSync.Outcome? {
        guard wantsSync(session) else {
            status = .off
            return nil
        }
        guard await environment.isAvailable() else {
            status = .unavailable("Sign in to iCloud on this device to sync.")
            return nil
        }

        let vaultID = session.header.vaultID
        loadStateIfNeeded(for: vaultID)
        status = .syncing
        var outcome = VaultSync.Outcome()
        var failure: (any Error)?
        var differentVault = false

        // Removals first, then discovery: a group this device deleted must not
        // be found again on the way out.
        await flushPendingRemovals()

        if !session.memberships.isEmpty || discoveryPending || session.settings.cloudSyncEnabled {
            do {
                try await discoverGroups(session: session)
                discoveryPending = false
            } catch {
                failure = error
            }
        }

        // The vault's own zone.
        if session.settings.cloudSyncEnabled {
            // A vault behind a USB security key cannot be shared: enabling the
            // key rotated the data key, and the other device — an iPhone, with
            // no port for the key file — could never derive the new one.
            // Settings stops the two being switched on together; this covers a
            // vault that already had both, and says why instead of syncing
            // nothing. Shared groups are unaffected: their zones are sealed
            // under their own keys, not the vault's.
            if session.header.unlockPolicy.requiresDevice {
                if session.memberships.isEmpty {
                    status = .unavailable("Paused while a USB security key protects this vault — it cannot be opened on an iPhone, so it is not shared through iCloud.")
                    return nil
                }
            } else {
                do {
                    let vaultOutcome = try await syncVaultZone(session: session)
                    outcome.pulled += vaultOutcome.outcome.pulled
                    outcome.pushed += vaultOutcome.outcome.pushed
                    outcome.deletedLocally += vaultOutcome.outcome.deletedLocally
                    outcome.conflicts += vaultOutcome.outcome.conflicts
                    differentVault = vaultOutcome.differentVault
                } catch {
                    if let syncError = error as? SyncError, case .differentVault = syncError {
                        differentVault = true
                    } else {
                        failure = error
                    }
                }
            }
        }

        // Each shared group's zone.
        for membership in session.memberships {
            do {
                let groupOutcome = try await syncGroupZone(membership, session: session)
                outcome.pulled += groupOutcome.pulled
                outcome.pushed += groupOutcome.pushed
                outcome.deletedLocally += groupOutcome.deletedLocally
                outcome.conflicts += groupOutcome.conflicts
            } catch {
                failure = error
            }
        }

        if differentVault {
            status = .differentVault
        } else if let failure {
            status = .failed(Self.describe(failure))
        } else {
            status = .idle(lastSynced: Date())
        }
        return failure == nil ? outcome : nil
    }

    // MARK: - The vault's zone

    private func syncVaultZone(session: VaultSession) async throws -> (outcome: VaultSync.Outcome, differentVault: Bool) {
        let backend = backend(for: session.header.vaultID)
        var working = bookkeeping.vault
        // A deletion noted while this run is in flight lands in the stored
        // state, not in the copy the run is working with. Remembering what
        // was owed at the start is what lets the two be reconciled at the end
        // instead of the run's copy silently discarding it.
        let owedAtStart = Set(working.pendingDeletions)
        do {
            let engine = VaultSync(backend: backend, dek: session.dek)
            // The header first: a device joining later needs it to derive the
            // data key from the master password. It refuses to overwrite a
            // different vault's header, which is also the earliest and
            // clearest signal that this account already holds another vault.
            try await engine.publishVault(
                header: session.header,
                replacingAnotherVault: claimCloudVaultOnNextSync
            )
            claimCloudVaultOnNextSync = false
            let pulled = try await engine.pull(state: &working)

            // Read, merge and write back with nothing awaited in between. The
            // fetch above can take seconds, and the user is in the app while
            // it runs: merging into a payload read *before* it would quietly
            // discard whatever they did meanwhile.
            var full = session.unlocked.payload
            var part = SharedGroupPartition.privatePart(of: full)
            let outcome = engine.merge(pulled, into: &part, state: &working)
            if outcome.changedLocally {
                // Only write the vault when something actually arrived, so a
                // quiet sync does not churn the file.
                SharedGroupPartition.adoptPrivate(part, into: &full)
                session.adoptSynced(full)
            }

            let pending = try engine.pendingPushes(payload: part, state: working)
            try await engine.push(pending, state: &working)
            commitVault(working, owedAtStart: owedAtStart)

            // Records belonging to a vault this device cannot open. Ignored
            // when this run pushed something: straight after a merge the
            // absorbed records still carry the other vault's id, and the push
            // that just re-sealed them is what clears it.
            let differentVault = await !backend.foreignVaultIDs.isEmpty && outcome.pulled == 0 && pending.isEmpty
            return (
                VaultSync.Outcome(
                    pulled: outcome.pulled,
                    pushed: pending.count,
                    deletedLocally: outcome.deletedLocally,
                    conflicts: outcome.conflicts
                ),
                differentVault
            )
        } catch {
            // Keep whatever progress the run did make — deletions it flushed
            // are already gone from the server, and re-sending them would be
            // pointless work on the next run.
            commitVault(working, owedAtStart: owedAtStart)
            throw error
        }
    }

    // MARK: - A shared group's zone

    private func syncGroupZone(_ membership: SharedGroupMembership, session: VaultSession) async throws -> VaultSync.Outcome {
        let backend = groupBackend(for: membership)
        var working = bookkeeping.groups[membership.id] ?? VaultSync.State()
        let owedAtStart = Set(working.pendingDeletions)
        do {
            let engine = VaultSync(backend: backend, dek: membership.symmetricKey)
            let pulled = try await engine.pull(state: &working)

            var full = session.unlocked.payload
            var part = SharedGroupPartition.groupPart(of: full, group: membership.id)
            let outcome = engine.merge(pulled, into: &part, state: &working)
            if outcome.changedLocally {
                SharedGroupPartition.adoptGroup(part, group: membership.id, into: &full)
                session.adoptSynced(full)
            }

            // A member whose copy of the group has not arrived yet holds a
            // stand-in for it. That is not something to send: the owner's
            // record is on its way, and the stand-in would only be overwritten.
            part.groups.removeAll(where: SharedGroupPartition.isPlaceholder)
            let pending = try engine.pendingPushes(payload: part, state: working)
            try await engine.push(pending, state: &working)
            commitGroup(membership.id, working, owedAtStart: owedAtStart)

            return VaultSync.Outcome(
                pulled: outcome.pulled,
                pushed: pending.count,
                deletedLocally: outcome.deletedLocally,
                conflicts: outcome.conflicts
            )
        } catch {
            commitGroup(membership.id, working, owedAtStart: owedAtStart)
            throw error
        }
    }

    /// Looks at the account for groups this device has not seen and groups
    /// it has lost, and brings the vault into line with it.
    private func discoverGroups(session: VaultSession) async throws {
        let found = try await environment.sharing.discover()
        let known = Set(session.memberships.map(\.id))
        let foundIDs = Set(found.map(\.id))
        let added = found.filter { !known.contains($0.id) }
        // A group this device is in the middle of removing is not "lost": it
        // is gone from the vault already, and iCloud is being told.
        let leaving = Set(bookkeeping.pendingRemovals.map(\.id))
        let removed = session.memberships
            .filter { !foundIDs.contains($0.id) && !leaving.contains($0.id) }
            .map(\.id)
        session.applyDiscovery(added: added, removed: removed)
        for id in removed {
            bookkeeping.groups.removeValue(forKey: id)
            groupBackends.removeValue(forKey: id)
        }
        if !removed.isEmpty { persistState() }
    }

    // MARK: - Creating, deleting and leaving shared groups

    /// Creates a shared group: its zone in iCloud first, then the group in the
    /// vault, so the vault never names a group that has nowhere to go.
    func createSharedGroup(name: String, session: VaultSession) async throws -> WalletGroup {
        guard await environment.isAvailable() else {
            throw SyncError.unavailable("Sign in to iCloud on this device to share wallets.")
        }
        let membership = SharedGroupMembership(key: SharedGroupMembership.newKey(), isOwner: true)
        try await environment.sharing.create(membership, name: name)
        let group = session.addSharedGroup(membership, name: name)
        // The group record goes up with the next run, which the write above
        // has already asked for.
        return group
    }

    /// A shared group left the vault. iCloud is told now, and if that fails
    /// the removal is kept and tried again on every run until it succeeds —
    /// a group that is gone from the vault but still in the account would be
    /// found and brought back by the next discovery.
    private func noteRemoval(of membership: SharedGroupMembership, session: VaultSession) {
        loadStateIfNeeded(for: session.header.vaultID)
        bookkeeping.groups.removeValue(forKey: membership.id)
        groupBackends.removeValue(forKey: membership.id)
        let removal = Bookkeeping.Removal(id: membership.id, isOwner: membership.isOwner, zoneOwnerName: membership.zoneOwnerName)
        if !bookkeeping.pendingRemovals.contains(where: { $0.id == removal.id }) {
            bookkeeping.pendingRemovals.append(removal)
        }
        persistState()
        scheduleSync(session: session)
    }

    private func flushPendingRemovals() async {
        for removal in bookkeeping.pendingRemovals {
            let membership = SharedGroupMembership(
                id: removal.id,
                key: Data(),
                isOwner: removal.isOwner,
                zoneOwnerName: removal.zoneOwnerName
            )
            do {
                try await environment.sharing.remove(membership)
                bookkeeping.pendingRemovals.removeAll { $0.id == removal.id }
                persistState()
            } catch {
                // Tried again next run.
            }
        }
    }

    // MARK: - Deletions

    /// Notes that a wallet is gone, so the next run tells iCloud.
    ///
    /// Recorded rather than sent right away, and written to disk before it is
    /// sent: a deletion that lives only in memory dies with the app, and the
    /// record it should have removed then comes back — restored onto the other
    /// device, and onto this one the next time it fetches the zone in full.
    func noteDeletion(walletID: UUID, inGroup groupID: UUID? = nil, session: VaultSession) {
        if let groupID, session.isShared(groupID) {
            note(session: session, group: groupID) { $0.noteDeletion(walletID: walletID) }
        } else {
            note(session: session, group: nil) { $0.noteDeletion(walletID: walletID) }
        }
    }

    /// Notes that a group is gone. Wallets inside it are not deleted anywhere;
    /// on the other device they simply stop being grouped.
    func noteDeletion(groupID: UUID, session: VaultSession) {
        note(session: session, group: nil) { $0.noteDeletion(groupID: groupID) }
    }

    private func note(session: VaultSession, group: UUID?, _ mutate: (inout VaultSync.State) -> Void) {
        if group == nil {
            guard session.settings.cloudSyncEnabled else { return }
        }
        loadStateIfNeeded(for: session.header.vaultID)
        if let group {
            var state = bookkeeping.groups[group] ?? VaultSync.State()
            mutate(&state)
            bookkeeping.groups[group] = state
        } else {
            mutate(&bookkeeping.vault)
        }
        // On disk before it is sent: if the app goes away now, the next launch
        // still owes iCloud this deletion.
        persistState()
        scheduleSync(session: session)
    }

    /// Drops work that has been asked for but not started.
    ///
    /// Called when the vault locks: a pending run holds the session, and with
    /// it the data key, which locking exists to let go of. Nothing is lost —
    /// what a run would have sent is already written down.
    func cancelPendingWork() {
        debounce?.cancel()
        debounce = nil
    }

    /// Pushes a vault that has just absorbed the iCloud one.
    ///
    /// The wallets it took on are still in the zone sealed under the *other*
    /// vault's key, and the vault record still names that vault. This run
    /// replaces both: the header becomes this vault's, and every absorbed
    /// wallet goes back up re-sealed under this vault's key. Without it the
    /// merge would look finished on this device while iCloud still held the
    /// old vault, and the next ordinary sync would refuse to touch it.
    func takeOverCloudVault(session: VaultSession) async {
        claimCloudVaultOnNextSync = true
        await syncIfEnabled(session: session)
    }

    /// Opens the vault that is in iCloud with its master password.
    ///
    /// Two backends: the first only reads the vault record, which is not
    /// filtered by vault id, and the second is built for the id it finds so the
    /// wallet records are not skipped as foreign.
    func fetchCloudVault(password: String) async throws -> (Vault.Unlocked, VaultSync.State) {
        let probe = environment.makeBackend(UUID())
        guard let remote = try await probe.fetchVault() else {
            throw SyncError.unavailable("There is no vault in iCloud yet.")
        }
        let backend = environment.makeBackend(remote.vaultID)
        let result = try await VaultSync.adoptRemoteVault(backend: backend, password: password)
        self.backend = backend
        self.backendVaultID = remote.vaultID
        self.bookkeeping = Bookkeeping(vault: result.state)
        self.groupBackends = [:]
        self.loadedStateFor = result.unlocked.header.vaultID
        // The groups the account is in are found on the first run.
        discoveryPending = true
        persistState()
        return (result.unlocked, result.state)
    }

    /// Works out what merging would add, without changing anything yet, so the
    /// user can be shown the count before agreeing to it.
    func previewCloudMerge(
        password: String,
        into local: Vault.Unlocked
    ) async throws -> (merged: Vault.Unlocked, adopted: Int) {
        let probe = environment.makeBackend(UUID())
        guard let remote = try await probe.fetchVault() else {
            throw SyncError.unavailable("There is no vault in iCloud yet.")
        }
        let backend = environment.makeBackend(remote.vaultID)
        return try await VaultSync.mergeRemoteVault(backend: backend, password: password, into: local)
    }

    /// Takes over the iCloud copy with this device's vault.
    ///
    /// The only resolution available when iCloud holds a *different* vault:
    /// those records are sealed under another master password, so this device
    /// cannot read, merge, or adopt them — it can only replace them. The other
    /// direction (adopting the iCloud vault) is a backup restore, because it
    /// needs that vault's password.
    func replaceCloudCopy(session: VaultSession) async {
        let backend = self.backend ?? environment.makeBackend(session.header.vaultID)
        status = .syncing
        do {
            // Not `try?`: a failed delete used to leave the old records in
            // place while reporting success, which looks exactly like the
            // button doing nothing.
            try await backend.removeEverything()
        } catch {
            status = .failed("Could not clear the iCloud copy: \(Self.describe(error))")
            return
        }

        // A fresh backend and empty bookkeeping, or the old change token would
        // point into a zone that no longer exists. The shared groups' zones
        // are untouched — they are not the vault's copy — so their
        // bookkeeping stays.
        self.backend = environment.makeBackend(session.header.vaultID)
        self.backendVaultID = session.header.vaultID
        loadStateIfNeeded(for: session.header.vaultID)
        bookkeeping.vault = VaultSync.State()
        persistState()

        await syncIfEnabled(session: session)
    }

    /// Removes this vault's records from iCloud and forgets the local
    /// bookkeeping, so turning sync back on starts clean.
    func removeFromCloud(session: VaultSession) async {
        let backend = self.backend ?? environment.makeBackend(session.header.vaultID)
        do {
            try await backend.removeEverything()
        } catch {
            status = .failed("Could not remove the iCloud copy: \(Self.describe(error))")
            return
        }
        loadStateIfNeeded(for: session.header.vaultID)
        bookkeeping.vault = VaultSync.State()
        if bookkeeping.groups.isEmpty && bookkeeping.pendingRemovals.isEmpty {
            await store.clearSyncState()
        } else {
            persistState()
        }
        status = .off
    }

    // MARK: - Persistence

    /// What a vault remembers between runs, for every zone it spans.
    private struct Bookkeeping: Codable {
        /// A removal still owed to iCloud: the zone to delete or the share to
        /// leave. The key is not kept — nothing in it needs the key, and the
        /// group is gone from the vault.
        struct Removal: Codable, Equatable {
            var id: UUID
            var isOwner: Bool
            var zoneOwnerName: String?
        }

        /// The vault's own zone. Called `state` on disk, which is what the
        /// file held before there were other zones.
        var vault = VaultSync.State()
        /// One per shared group, by group id.
        var groups: [UUID: VaultSync.State] = [:]
        var pendingRemovals: [Removal] = []

        init(vault: VaultSync.State = VaultSync.State()) {
            self.vault = vault
        }

        enum CodingKeys: String, CodingKey {
            case vault = "state"
            case groups, pendingRemovals
        }

        /// Hand-written so a file from before shared groups still decodes
        /// rather than throwing the vault's bookkeeping away.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            vault = try container.decodeIfPresent(VaultSync.State.self, forKey: .vault) ?? VaultSync.State()
            let stored = try container.decodeIfPresent([String: VaultSync.State].self, forKey: .groups) ?? [:]
            var groups: [UUID: VaultSync.State] = [:]
            for (key, state) in stored {
                if let id = UUID(uuidString: key) { groups[id] = state }
            }
            self.groups = groups
            pendingRemovals = try container.decodeIfPresent([Removal].self, forKey: .pendingRemovals) ?? []
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(vault, forKey: .vault)
            var stored: [String: VaultSync.State] = [:]
            for (id, state) in groups { stored[id.uuidString] = state }
            try container.encode(stored, forKey: .groups)
            try container.encode(pendingRemovals, forKey: .pendingRemovals)
        }
    }

    /// Bookkeeping is per vault: state from a different vault would claim
    /// wallets had been synced that never were.
    private struct Stored: Codable {
        var vaultID: UUID
        var bookkeeping: Bookkeeping

        enum CodingKeys: String, CodingKey { case vaultID }

        init(vaultID: UUID, bookkeeping: Bookkeeping) {
            self.vaultID = vaultID
            self.bookkeeping = bookkeeping
        }

        // The bookkeeping's own keys sit beside the vault id at the top level,
        // which is the shape the file has always had.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            vaultID = try container.decode(UUID.self, forKey: .vaultID)
            bookkeeping = try Bookkeeping(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(vaultID, forKey: .vaultID)
            try bookkeeping.encode(to: encoder)
        }
    }

    /// Writes a finished run's bookkeeping back, carrying over any deletion
    /// noted while it was running.
    private func commitVault(_ finished: VaultSync.State, owedAtStart: Set<String>) {
        bookkeeping.vault = Self.reconcile(finished, current: bookkeeping.vault, owedAtStart: owedAtStart)
        persistState()
    }

    private func commitGroup(_ id: UUID, _ finished: VaultSync.State, owedAtStart: Set<String>) {
        // A group removed while its run was in flight stays removed.
        guard bookkeeping.pendingRemovals.allSatisfy({ $0.id != id }) else { return }
        let current = bookkeeping.groups[id] ?? VaultSync.State()
        bookkeeping.groups[id] = Self.reconcile(finished, current: current, owedAtStart: owedAtStart)
        persistState()
    }

    private static func reconcile(_ finished: VaultSync.State, current: VaultSync.State, owedAtStart: Set<String>) -> VaultSync.State {
        var next = finished
        for key in current.pendingDeletions where !owedAtStart.contains(key) && !next.pendingDeletions.contains(key) {
            next.pendingDeletions.append(key)
        }
        return next
    }

    private func backend(for vaultID: UUID) -> any CloudBackend {
        loadStateIfNeeded(for: vaultID)
        if let backend, backendVaultID == vaultID { return backend }
        let created = environment.makeBackend(vaultID)
        backend = created
        backendVaultID = vaultID
        return created
    }

    private func groupBackend(for membership: SharedGroupMembership) -> any SyncBackend {
        if let existing = groupBackends[membership.id] { return existing }
        let created = environment.sharing.makeBackend(for: membership)
        groupBackends[membership.id] = created
        return created
    }

    private func loadStateIfNeeded(for vaultID: UUID) {
        guard loadedStateFor != vaultID else { return }
        bookkeeping = loadState(for: vaultID)
        groupBackends = [:]
        loadedStateFor = vaultID
    }

    private func loadState(for vaultID: UUID) -> Bookkeeping {
        guard let data = try? Data(contentsOf: store.syncStateURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.vaultID == vaultID
        else { return Bookkeeping() }
        return stored.bookkeeping
    }

    private func persistState() {
        guard let vaultID = loadedStateFor,
              let data = try? JSONEncoder().encode(Stored(vaultID: vaultID, bookkeeping: bookkeeping))
        else { return }
        // Now, not on a queue: this is where a deletion lives until iCloud has
        // been told, and the app can go away at any moment.
        try? store.saveSyncStateNow(data)
    }

    private static func describe(_ error: any Error) -> String {
        // CloudKit's localizedDescription is often just "an error occurred",
        // so carry the code too — without it a failure cannot be diagnosed.
        if let ckError = error as? CKError {
            return "\(ckError.localizedDescription) [CloudKit \(ckError.code.rawValue)]"
        }
        if let syncError = error as? SyncError {
            switch syncError {
            case .differentVault: return "This iCloud account holds a different vault."
            case .unavailable(let reason): return reason
            }
        }
        return error.localizedDescription
    }
}
