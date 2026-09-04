import Foundation
import CloudKit
import SafeKeyCore

/// Drives sync for an unlocked vault: holds the engine, the persisted state,
/// and the status the UI shows.
///
/// Only ever runs while the vault is unlocked, because merging needs the data
/// key. A locked app syncs nothing — there is nothing it could read.
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
        /// How long a change waits for company before it is synced. Editing a
        /// wallet writes more than once, and each write asks for a run.
        var editDebounce: Duration = .seconds(2)

        static let cloudKit = Environment(
            isAvailable: { await CloudKitSyncBackend.isAvailable() },
            makeBackend: { CloudKitSyncBackend(vaultID: $0) }
        )
    }

    private(set) var status: Status = .off
    private let store: VaultStore
    private let environment: Environment
    private var backend: (any CloudBackend)?
    private var backendVaultID: UUID?
    private var state = VaultSync.State()
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
        session.onDelete = { [weak self, weak session] deletion in
            guard let self, let session else { return }
            switch deletion {
            case .wallet(let id): self.noteDeletion(walletID: id, session: session)
            case .group(let id): self.noteDeletion(groupID: id, session: session)
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
        guard session.settings.cloudSyncEnabled else { return }
        let delay = environment.editDebounce
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncIfEnabled(session: session)
        }
    }

    private func performSync(session: VaultSession) async -> VaultSync.Outcome? {
        guard session.settings.cloudSyncEnabled else {
            status = .off
            return nil
        }
        // A vault behind a USB security key cannot be shared: enabling the key
        // rotated the data key, and the other device — an iPhone, with no port
        // for the key file — could never derive the new one. Settings stops
        // the two being switched on together; this covers a vault that already
        // had both, and says why instead of syncing nothing.
        guard !session.header.unlockPolicy.requiresDevice else {
            status = .unavailable("Paused while a USB security key protects this vault — it cannot be opened on an iPhone, so it is not shared through iCloud.")
            return nil
        }
        guard await environment.isAvailable() else {
            status = .unavailable("Sign in to iCloud on this device to sync.")
            return nil
        }

        let vaultID = session.header.vaultID
        let backend = backend(for: vaultID)
        status = .syncing
        var working = state
        // A deletion noted while this run is in flight lands in `state`, not in
        // the copy the run is working with. Remembering what was owed at the
        // start is what lets the two be reconciled at the end instead of the
        // run's copy silently discarding it.
        let owedAtStart = Set(state.pendingDeletions)
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
            var payload = session.unlocked.payload
            let outcome = engine.merge(pulled, into: &payload, state: &working)
            if outcome.changedLocally {
                // Only write the vault when something actually arrived, so a
                // quiet sync does not churn the file.
                session.adoptSynced(payload)
            }

            let pending = try engine.pendingPushes(payload: payload, state: working)
            try await engine.push(pending, state: &working)
            commit(working, owedAtStart: owedAtStart)

            // Records belonging to a vault this device cannot open. Ignored
            // when this run pushed something: straight after a merge the
            // absorbed records still carry the other vault's id, and the push
            // that just re-sealed them is what clears it.
            if await !backend.foreignVaultIDs.isEmpty, outcome.pulled == 0, pending.isEmpty {
                status = .differentVault
            } else {
                status = .idle(lastSynced: Date())
            }
            return VaultSync.Outcome(
                pulled: outcome.pulled,
                pushed: pending.count,
                deletedLocally: outcome.deletedLocally,
                conflicts: outcome.conflicts
            )
        } catch {
            // Keep whatever progress the run did make — deletions it flushed
            // are already gone from the server, and re-sending them would be
            // pointless work on the next run.
            commit(working, owedAtStart: owedAtStart)
            if let syncError = error as? SyncError, case .differentVault = syncError {
                status = .differentVault
            } else {
                status = .failed(Self.describe(error))
            }
            return nil
        }
    }

    /// Notes that a wallet is gone, so the next run tells iCloud.
    ///
    /// Recorded rather than sent right away, and written to disk before it is
    /// sent: a deletion that lives only in memory dies with the app, and the
    /// record it should have removed then comes back — restored onto the other
    /// device, and onto this one the next time it fetches the zone in full.
    func noteDeletion(walletID: UUID, session: VaultSession) {
        note(session: session) { $0.noteDeletion(walletID: walletID) }
    }

    /// Notes that a group is gone. Wallets inside it are not deleted anywhere;
    /// on the other device they simply stop being grouped.
    func noteDeletion(groupID: UUID, session: VaultSession) {
        note(session: session) { $0.noteDeletion(groupID: groupID) }
    }

    private func note(session: VaultSession, _ mutate: (inout VaultSync.State) -> Void) {
        guard session.settings.cloudSyncEnabled else { return }
        loadStateIfNeeded(for: session.header.vaultID)
        mutate(&state)
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
        self.state = result.state
        self.loadedStateFor = result.unlocked.header.vaultID
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
        // point into a zone that no longer exists.
        self.backend = environment.makeBackend(session.header.vaultID)
        self.backendVaultID = session.header.vaultID
        state = VaultSync.State()
        loadedStateFor = session.header.vaultID
        await store.clearSyncState()

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
        state = VaultSync.State()
        await store.clearSyncState()
        status = .off
    }

    // MARK: - Persistence

    /// Writes a finished run's bookkeeping back, carrying over any deletion
    /// noted while it was running.
    private func commit(_ finished: VaultSync.State, owedAtStart: Set<String>) {
        var next = finished
        for key in state.pendingDeletions where !owedAtStart.contains(key) && !next.pendingDeletions.contains(key) {
            next.pendingDeletions.append(key)
        }
        state = next
        persistState()
    }

    private func backend(for vaultID: UUID) -> any CloudBackend {
        loadStateIfNeeded(for: vaultID)
        if let backend, backendVaultID == vaultID { return backend }
        let created = environment.makeBackend(vaultID)
        backend = created
        backendVaultID = vaultID
        return created
    }

    private func loadStateIfNeeded(for vaultID: UUID) {
        guard loadedStateFor != vaultID else { return }
        state = loadState(for: vaultID)
        loadedStateFor = vaultID
    }

    private func loadState(for vaultID: UUID) -> VaultSync.State {
        // Bookkeeping is per vault: state from a different vault would claim
        // wallets had been synced that never were.
        struct Stored: Codable { var vaultID: UUID; var state: VaultSync.State }
        guard let data = try? Data(contentsOf: store.syncStateURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.vaultID == vaultID
        else { return VaultSync.State() }
        return stored.state
    }

    private func persistState() {
        struct Stored: Codable { var vaultID: UUID; var state: VaultSync.State }
        guard let vaultID = loadedStateFor,
              let data = try? JSONEncoder().encode(Stored(vaultID: vaultID, state: state))
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
