import Foundation
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
            let outcome = try await VaultSync(backend: backend, dek: session.dek)
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

    /// Removes this vault's records from iCloud and forgets the local
    /// bookkeeping, so turning sync back on starts clean.
    func removeFromCloud(session: VaultSession) async {
        let backend = self.backend ?? CloudKitSyncBackend(vaultID: session.header.vaultID)
        try? await backend.removeEverything()
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
        if let syncError = error as? SyncError {
            switch syncError {
            case .differentVault: return "This iCloud account holds a different vault."
            case .unavailable(let reason): return reason
            }
        }
        return error.localizedDescription
    }
}
