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

    private(set) var status: Status = .off
    private let store: VaultStore
    private var backend: CloudKitSyncBackend?
    private var state = VaultSync.State()
    private var loadedStateFor: UUID?

    init(store: VaultStore) {
        self.store = store
    }

    /// Syncs if the vault has it switched on. Safe to call often — it returns
    /// immediately when sync is off, and never throws into the caller: a sync
    /// problem must not interrupt using the vault.
    @discardableResult
    func syncIfEnabled(session: VaultSession) async -> VaultSync.Outcome? {
        guard session.settings.cloudSyncEnabled else {
            status = .off
            return nil
        }
        guard await CloudKitSyncBackend.isAvailable() else {
            status = .unavailable("Sign in to iCloud on this device to sync.")
            return nil
        }

        let vaultID = session.header.vaultID
        if loadedStateFor != vaultID {
            state = loadState(for: vaultID)
            loadedStateFor = vaultID
        }
        let backend = backend ?? CloudKitSyncBackend(vaultID: vaultID)
        self.backend = backend

        status = .syncing
        var payload = session.unlocked.payload
        var working = state
        do {
            let engine = VaultSync(backend: backend, dek: session.dek)
            // The header first: a device joining later needs it to derive the
            // data key from the master password.
            try await engine.publishVault(header: session.header)
            let outcome = try await engine
                .run(payload: &payload, state: &working)
            state = working
            persistState()

            if outcome.pulled > 0 || outcome.conflicts > 0 || outcome.deletedLocally > 0 {
                // Only write the vault when something actually arrived, so a
                // quiet sync does not churn the file.
                session.adoptSynced(payload)
            }
            if await !backend.foreignVaultIDs.isEmpty, outcome.pulled == 0 {
                status = .differentVault
            } else {
                status = .idle(lastSynced: Date())
            }
            return outcome
        } catch {
            status = .failed(Self.describe(error))
            return nil
        }
    }

    /// Tells iCloud a wallet is gone. Without this the other device would
    /// restore it on its next sync.
    func recordDeletion(of id: UUID, session: VaultSession) async {
        guard session.settings.cloudSyncEnabled, let backend else { return }
        var working = state
        try? await VaultSync(backend: backend, dek: session.dek)
            .pushDeletion(of: [id], state: &working)
        state = working
        persistState()
    }

    /// Opens the vault that is in iCloud with its master password.
    ///
    /// Two backends: the first only reads the vault record, which is not
    /// filtered by vault id, and the second is built for the id it finds so the
    /// wallet records are not skipped as foreign.
    func fetchCloudVault(password: String) async throws -> (Vault.Unlocked, VaultSync.State) {
        let probe = CloudKitSyncBackend(vaultID: UUID())
        guard let remote = try await probe.fetchVault() else {
            throw SyncError.unavailable("There is no vault in iCloud yet.")
        }
        let backend = CloudKitSyncBackend(vaultID: remote.vaultID)
        let result = try await VaultSync.adoptRemoteVault(backend: backend, password: password)
        self.backend = backend
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
        let probe = CloudKitSyncBackend(vaultID: UUID())
        guard let remote = try await probe.fetchVault() else {
            throw SyncError.unavailable("There is no vault in iCloud yet.")
        }
        let backend = CloudKitSyncBackend(vaultID: remote.vaultID)
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
        let backend = self.backend ?? CloudKitSyncBackend(vaultID: session.header.vaultID)
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
        self.backend = CloudKitSyncBackend(vaultID: session.header.vaultID)
        state = VaultSync.State()
        loadedStateFor = session.header.vaultID
        await store.clearSyncState()

        await syncIfEnabled(session: session)
    }

    /// Removes this vault's records from iCloud and forgets the local
    /// bookkeeping, so turning sync back on starts clean.
    func removeFromCloud(session: VaultSession) async {
        let backend = self.backend ?? CloudKitSyncBackend(vaultID: session.header.vaultID)
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
        let store = self.store
        Task { try? await store.saveSyncState(data) }
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
