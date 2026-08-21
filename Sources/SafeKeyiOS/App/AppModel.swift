import Foundation
import CryptoKit
import LocalAuthentication
import Observation
import SwiftUI
import SafeKeyCore

/// Root state machine for the iOS app.
///
/// Deliberately narrower than the Mac version. Dropped for iOS:
///
/// - **USB security key** — iPhones have no port for it.
/// - **App disguise** — the sandbox forbids an app rewriting its own bundle,
///   and a concealment feature is a poor fit for App Store review. Alternate
///   app icons are the sanctioned equivalent if wanted later.
/// - **Screen-capture blocking** — handled differently on iOS.
///
/// Everything security-critical comes from `SafeKeyCore`, which is the same
/// audited source the Mac app compiles.
@MainActor
@Observable
final class AppModel {
    enum AppState {
        case loading
        case noVault
        case locked
        case unlocked(VaultSession)
    }

    private(set) var state: AppState = .loading
    let store: VaultStore
    let keychain: KeychainService
    private(set) var lockedHeader: VaultHeader?
    private(set) var tamperDetected = false
    private(set) var remainingAttempts: Int?
    private(set) var canUnlockWithBiometrics = false

    /// Shares the Keychain service with `keychain`, so the biometric copy of
    /// the data key lives in the same namespace self-destruct wipes — and so
    /// an isolated (test) vault cannot reach the real one's biometric key.
    let biometricFactor: BiometricFactor
    /// Sync only ever runs while unlocked — merging needs the data key.
    let sync: SyncCoordinator

    init(store: VaultStore = VaultStore(), keychain: KeychainService = KeychainService()) {
        self.store = store
        self.keychain = keychain
        self.biometricFactor = BiometricFactor(service: keychain.service)
        self.sync = SyncCoordinator(store: store)
    }

    /// The model the app scene should use.
    ///
    /// UI tests pass `--uitest` to get a vault in a scratch directory under its
    /// own Keychain service, so a test run can never read, damage, or
    /// self-destruct a real vault. `--uitest-reset` additionally wipes that
    /// scratch state, giving a first-launch app. Compiled out of release builds
    /// entirely: a shipping binary has no code path that relocates the vault.
    static func forCurrentLaunch() -> AppModel {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitest") else { return AppModel() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeyUITests", isDirectory: true)
        let keychain = KeychainService(service: "com.andri.safekey.uitest")
        if arguments.contains("--uitest-reset") {
            try? FileManager.default.removeItem(at: directory)
            try? keychain.deleteAll()
        }
        return AppModel(store: VaultStore(directory: directory), keychain: keychain)
        #else
        return AppModel()
        #endif
    }

    private var anchors: VaultAnchorStore {
        VaultAnchorStore(keychain: keychain, directory: store.directoryURL)
    }

    var session: VaultSession? {
        if case .unlocked(let session) = state { return session }
        return nil
    }

    /// Face ID / Touch ID, whichever this device has.
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Biometrics"
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        if await store.vaultExists() {
            await refreshLockedState()
            state = .locked
        } else {
            state = .noVault
        }
    }

    private func refreshLockedState() async {
        if let container = try? await store.read(),
           let decoded = try? VaultFileFormat.decode(container) {
            lockedHeader = decoded.header
            tamperDetected = anchors.containerWasModified(container: container)
        } else {
            lockedHeader = nil
            tamperDetected = false
        }
        remainingAttempts = anchors.remainingAttempts()
        refreshBiometricAvailability()
    }

    func refreshBiometricAvailability() {
        guard let header = lockedHeader else {
            canUnlockWithBiometrics = false
            return
        }
        canUnlockWithBiometrics = BiometricFactor.isBiometryAvailable()
            && biometricFactor.isEnrolled(vaultID: header.vaultID)
    }

    func lock() {
        sync.cancelPendingWork()
        guard case .unlocked = state else { return }
        lockedHeader = session?.header
        state = .locked
        refreshBiometricAvailability()
        remainingAttempts = anchors.remainingAttempts()
    }

    // MARK: - Create / unlock

    func createVault(password: String) async throws {
        let (container, unlocked) = try await Task.detached(priority: .userInitiated) {
            try Vault.create(password: password)
        }.value
        try await store.write(container)
        anchors.clear()
        adopt(unlocked, container: container)
        session?.isNewlyCreated = true
    }

    func unlock(password: String) async throws {
        let container = try await store.read()
        do {
            let unlocked = try await Task.detached(priority: .userInitiated) {
                try Vault.unlock(container: container, password: password)
            }.value
            adopt(unlocked, container: container)
        } catch VaultError.wrongPassword {
            try await registerFailedAttempt(container: container)
            throw VaultError.wrongPassword
        } catch VaultError.tampered {
            // The password was right; the data is damaged. Never counted as a
            // failed credential attempt, or corrupting the payload would be a
            // way to force a self-destruct.
            tamperDetected = true
            throw VaultError.tampered
        }
    }

    func unlockWithBiometrics(context: LAContext? = nil) async throws {
        guard let header = lockedHeader else { throw BiometricError.notEnrolled }
        let blob: Data
        do {
            blob = try await biometricFactor.obtainSecret(
                vaultID: header.vaultID,
                reason: "unlock your vault",
                context: context
            )
        } catch BiometricError.notEnrolled {
            biometricFactor.forgetStrategyMarker(vaultID: header.vaultID)
            refreshBiometricAvailability()
            throw BiometricError.notEnrolled
        }
        let container = try await store.read()
        let unlocked = try Vault.unlock(container: container, dek: SymmetricKey(data: blob))
        adopt(unlocked, container: container)
    }

    @discardableResult
    func enableBiometricUnlock(confirm: Bool = true) async throws -> BiometricFactor.Strategy {
        guard let session else { throw BiometricError.notEnrolled }
        let blob = session.dek.withUnsafeBytes { Data($0) }
        return try await biometricFactor.enable(
            secret: blob,
            vaultID: session.header.vaultID,
            confirm: confirm,
            reason: "enable \(biometryName) unlock for this vault"
        )
    }

    func disableBiometricUnlock() throws {
        guard let session else { throw VaultError.vaultNotFound }
        try biometricFactor.disable(vaultID: session.header.vaultID)
    }

    /// Replaces this device's vault with the one in iCloud, after unlocking it
    /// with its master password.
    ///
    /// Destructive locally, which is why the caller confirms first: the wallets
    /// on this device are not merged into the iCloud vault, they are replaced
    /// by it. A rescue copy of the outgoing vault is kept so a mistake here is
    /// recoverable.
    func adoptCloudVault(password: String) async throws {
        let (unlocked, _) = try await sync.fetchCloudVault(password: password)
        if let current = try? await store.read() {
            try? await store.writeRescueCopy(current)
        }
        let container = try Vault.seal(unlocked)
        try Vault.validate(container: container, dek: unlocked.dek)
        try await store.write(container)
        anchors.clear()
        adopt(unlocked, container: container)
    }

    /// What merging the iCloud vault into this one would add. Nothing is
    /// written; the result is held so the user can confirm the count first.
    func previewCloudMerge(password: String) async throws -> (Vault.Unlocked, Int) {
        guard let session else { throw VaultError.vaultNotFound }
        await session.flushPendingSaves()
        return try await sync.previewCloudMerge(password: password, into: session.unlocked)
    }

    /// Commits a merge the user has agreed to, then pushes the combined set so
    /// the other device receives what it was missing.
    func applyCloudMerge(_ merged: Vault.Unlocked) async throws {
        guard let session else { throw VaultError.vaultNotFound }
        if let current = try? await store.read() {
            try? await store.writeRescueCopy(current)
        }
        try await session.adopt(merged)
        // Take over rather than sync: the wallets just absorbed are still in
        // iCloud sealed under the other vault's key, and the vault record
        // still names it.
        await sync.takeOverCloudVault(session: session)
    }

    // MARK: - Master password

    /// Re-wraps the DEK under a new password. The DEK itself is unchanged, so
    /// the biometric Keychain copy stays valid and no entry is re-encrypted.
    func changePassword(old: String, new: String) async throws {
        guard let session else { throw VaultError.vaultNotFound }
        await session.flushPendingSaves()
        let container = try Vault.seal(session.unlocked)
        let changed = try await Task.detached(priority: .userInitiated) {
            try Vault.changePassword(container: container, oldPassword: old, newPassword: new)
        }.value
        // We already hold the DEK, so reopening here is a self-consistency
        // check that the new container works — not a policy gate.
        let reopened = try Vault.unlock(container: changed, dek: session.dek)
        try await session.adopt(reopened)
    }

    // MARK: - Self-destruct accounting

    private func registerFailedAttempt(container: Data) async throws {
        if let header = try? VaultFileFormat.decode(container).header {
            lockedHeader = header
        }
        let outcome = anchors.registerFailure(
            currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: container)
        )
        remainingAttempts = outcome.remaining
        if outcome.headerMismatch {
            // Never destroy on a header we did not pin: otherwise someone who
            // cannot open the vault could still arrange for the owner's own
            // correct password to erase it.
            tamperDetected = true
            return
        }
        if outcome.shouldDestroy {
            await SelfDestruct.execute(store: store, keychain: keychain, biometricFactor: biometricFactor)
            anchors.clear()
            lockedHeader = nil
            state = .noVault
            throw VaultError.vaultNotFound
        }
    }

    // MARK: - Backup

    func exportVaultData() throws -> Data {
        guard let session else { throw VaultError.vaultNotFound }
        return try Vault.seal(session.unlocked)
    }

    func inspectBackup(_ data: Data) throws -> VaultHeader {
        try VaultFileFormat.decode(data).header
    }

    func importVault(_ data: Data) async throws {
        let header = try VaultFileFormat.decode(data).header
        if let current = try? await store.read() {
            try? await store.writeRescueCopy(current)
        }
        try await store.write(data)
        anchors.clear()
        anchors.pin(container: data)
        biometricFactor.pruneStrategyMarkers(keeping: header.vaultID)
        biometricFactor.forgetStrategyMarker(vaultID: header.vaultID)
        lockedHeader = header
        tamperDetected = false
        state = .locked
        refreshBiometricAvailability()
        remainingAttempts = anchors.remainingAttempts()
    }

    // MARK: - Session adoption

    private func adopt(_ unlocked: Vault.Unlocked, container: Data) {
        anchors.pin(container: container)
        tamperDetected = false
        remainingAttempts = anchors.remainingAttempts()
        biometricFactor.pruneStrategyMarkers(keeping: unlocked.header.vaultID)
        Task { await store.clearRescueCopy() }
        reprovisionBiometricKeyIfEnabled(unlocked)
        let session = VaultSession(unlocked: unlocked, store: store, onPersist: { [weak self] written, _ in
            self?.anchors.pin(container: written)
        })
        sync.attach(to: session)
        state = .unlocked(session)
        // Pull anything the other device added while this one was locked.
        Task { [weak self] in await self?.sync.syncIfEnabled(session: session) }
    }

    /// Rewrites the biometric key on each unlock so its Keychain protection
    /// always matches the running build.
    private func reprovisionBiometricKeyIfEnabled(_ unlocked: Vault.Unlocked) {
        guard biometricFactor.isEnabled(vaultID: unlocked.header.vaultID) else { return }
        let blob = unlocked.dek.withUnsafeBytes { Data($0) }
        Task { [weak self] in
            _ = try? await self?.biometricFactor.enable(
                secret: blob,
                vaultID: unlocked.header.vaultID,
                confirm: false
            )
            self?.refreshBiometricAvailability()
        }
    }
}
