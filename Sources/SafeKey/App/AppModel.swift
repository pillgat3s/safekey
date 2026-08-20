import Foundation
import CryptoKit
import LocalAuthentication
import Observation
import SafeKeyCore

/// Root state machine. All UI state lives on the main actor; the expensive
/// KDF work runs detached so unlock never blocks rendering.
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
    private let autoLock = AutoLockService()
    /// Header of the locked vault, for unlock-screen UI (KDF params, policies).
    private(set) var lockedHeader: VaultHeader?

    init(store: VaultStore = VaultStore(), keychain: KeychainService = KeychainService()) {
        self.store = store
        self.keychain = keychain
    }

    private var activeStore: VaultStore { demoState?.0 ?? store }

    /// Trusted policy/counter store. Never reads the on-disk header.
    private var anchors: VaultAnchorStore {
        VaultAnchorStore(keychain: keychain, directory: activeStore.directoryURL)
    }

    /// Set when the vault file differs from the one pinned at the last
    /// successful unlock — i.e. it was modified behind our back. Computed
    /// without any password input, so it is not an oracle.
    private(set) var tamperDetected = false

    /// Attempts left before self-destruct fires; nil when not armed.
    ///
    /// Cached observable state, not a computed property: reading it touches the
    /// Keychain, a file, a JSON decode and an HMAC verification, and SwiftUI
    /// re-evaluates view bodies on every keystroke. It is refreshed at the
    /// points where it can actually change.
    private(set) var remainingAttempts: Int?

    func refreshAttemptDisplay() {
        remainingAttempts = anchors.remainingAttempts()
    }

    // MARK: - USB security key

    let deviceKeyProvider: any DeviceKeyProvider = VolumeDeviceKeyProvider()
    let volumeWatcher = VolumeWatcher()

    var requiresDeviceKey: Bool {
        lockedHeader?.unlockPolicy.requiresDevice ?? false
    }

    private func syncVolumeWatcher() {
        if case .locked = state, let header = lockedHeader, header.unlockPolicy.requiresDevice {
            volumeWatcher.start(policy: header.unlockPolicy)
        } else {
            volumeWatcher.stop()
        }
    }

    // MARK: - Biometrics

    let biometricFactor = BiometricFactor()

    /// Cached: the enrolment check touches the Keychain, and SwiftUI reads this
    /// from view bodies on every render.
    private(set) var canUnlockWithBiometrics = false

    func refreshBiometricAvailability() {
        guard let header = lockedHeader else {
            canUnlockWithBiometrics = false
            return
        }
        canUnlockWithBiometrics = BiometricFactor.isBiometryAvailable()
            && biometricFactor.isEnrolled(vaultID: header.vaultID)
    }

    /// Touch ID path: the Keychain blob is the raw DEK, or — when the USB
    /// device factor is on — the DEK wrapped under the device key, in which
    /// case the stick must be present too. Biometric failures never count
    /// toward self-destruct (macOS enforces its own biometry lockout).
    func unlockWithBiometrics(deviceKey: Data? = nil, context: LAContext? = nil) async throws {
        guard let header = lockedHeader else { throw BiometricError.notEnrolled }
        let blob: Data
        do {
            blob = try await biometricFactor.obtainSecret(
                vaultID: header.vaultID,
                reason: "unlock your vault",
                context: context
            )
        } catch BiometricError.notEnrolled {
            // The marker outlived the key — usually because the app was
            // reinstalled or re-signed. Drop it so the UI stops offering a
            // button that cannot work.
            biometricFactor.forgetStrategyMarker(vaultID: header.vaultID)
            refreshBiometricAvailability()
            throw BiometricError.notEnrolled
        }
        let dek: SymmetricKey
        if header.unlockPolicy.requiresDevice {
            guard let deviceKey else { throw VaultError.deviceKeyRequired }
            dek = try VaultCrypto.unwrapDEK(blob, under: SymmetricKey(data: deviceKey))
        } else {
            dek = SymmetricKey(data: blob)
        }
        let container = try await activeStore.read()
        let unlocked = try Vault.unlock(
            container: container,
            dek: dek,
            deviceKeyWasPresented: deviceKey != nil
        )
        adoptUnlockedSession(unlocked, container: container, store: activeStore)
    }

    /// Stores the biometric DEK copy. With the device factor on, stores the
    /// DEK wrapped under the device key instead so Touch ID alone is never
    /// sufficient. Returns the strategy that ended up active.
    @discardableResult
    func enableBiometricUnlock(deviceKey: Data? = nil, confirm: Bool = true) async throws -> BiometricFactor.Strategy {
        guard let session else { throw BiometricError.notEnrolled }
        let blob: Data
        if session.header.unlockPolicy.requiresDevice {
            guard let deviceKey else { throw VaultError.deviceKeyRequired }
            blob = try VaultCrypto.wrapDEK(session.dek, under: SymmetricKey(data: deviceKey))
        } else {
            blob = session.dek.withUnsafeBytes { Data($0) }
        }
        return try await biometricFactor.enable(
            secret: blob,
            vaultID: session.header.vaultID,
            confirm: confirm
        )
    }

    /// Revocation must not silently no-op: a caller that reports success while
    /// the biometric copy of the DEK is still in the Keychain is worse than an
    /// error.
    func disableBiometricUnlock() throws {
        guard let session else { throw VaultError.vaultNotFound }
        try biometricFactor.disable(vaultID: session.header.vaultID)
    }

    // MARK: - Credential management (all require the unlocked session)

    func changePassword(old: String, new: String) async throws {
        guard let session else { throw VaultError.vaultNotFound }
        let deviceKey = try currentDeviceKeyIfRequired(header: session.header)
        await session.flushPendingSaves()
        let container = try Vault.seal(session.unlocked)
        let changed = try await Task.detached(priority: .userInitiated) {
            try Vault.changePassword(container: container, oldPassword: old, newPassword: new, deviceKey: deviceKey)
        }.value
        // We hold the DEK already, so this is validation, not a policy gate.
        let reopened = try Vault.unlock(container: changed, dek: session.dek, deviceKeyWasPresented: true)
        try await session.adopt(reopened)
    }

    /// Turns the USB security-key factor on: writes a fresh device key to the
    /// chosen volume, re-wraps the vault, updates the biometric blob, and
    /// returns the key bytes so the UI can offer a backup export.
    @discardableResult
    func enableDeviceFactor(password: String, volume: RemovableVolume) async throws -> Data {
        guard let session else { throw VaultError.vaultNotFound }
        let currentDeviceKey = try currentDeviceKeyIfRequired(header: session.header)
        await session.flushPendingSaves()
        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let relPath = VolumeDeviceKeyProvider.defaultKeyRelPath

        let policy = UnlockPolicy(
            requiresDevice: true,
            volumeUUID: volume.uuid,
            volumeName: volume.name,
            keyFileRelPath: relPath
        )
        // Re-wrap *before* touching the stick: a wrong password must not leave
        // a live-looking key file at the well-known path.
        let current = session.unlocked
        let updated = try await Task.detached(priority: .userInitiated) {
            try DeviceKeyFactor.apply(
                to: current, password: password,
                currentDeviceKey: currentDeviceKey,
                newPolicy: policy, newDeviceKey: deviceKey
            )
        }.value

        try deviceKeyProvider.writeKey(deviceKey, volumeURL: volume.url, relPath: relPath)
        do {
            try await session.adopt(updated)
        } catch {
            // The vault still requires the old credentials; drop the orphan.
            deviceKeyProvider.removeKey(volumeURL: volume.url, relPath: relPath)
            throw error
        }
        // The DEK was rotated, so any stored biometric copy is now dead and
        // MUST be replaced or removed — never left stale.
        if biometricFactor.isEnabled(vaultID: updated.header.vaultID) {
            await refreshBiometricBlob(deviceKey: deviceKey, vaultID: updated.header.vaultID)
        }
        return deviceKey
    }

    /// Re-stores the biometric DEK copy after a DEK rotation. If it cannot be
    /// re-stored, biometric unlock is disabled rather than left pointing at a
    /// key that no longer opens the vault.
    /// Rewrites the stored biometric key on every successful unlock.
    ///
    /// A login-keychain item's ACL is tied to the build that created it, so an
    /// item written by an earlier build stops being readable and macOS falls
    /// back to demanding the login password. Re-writing it while the vault is
    /// open — the one moment the key is available — keeps the ACL matched to
    /// the running build, so Touch ID survives reinstalls instead of silently
    /// dying. Failure here is not fatal: the existing enrolment is left alone.
    private func reprovisionBiometricKeyIfEnabled() {
        guard let session, biometricFactor.isEnabled(vaultID: session.header.vaultID) else { return }
        let policy = session.header.unlockPolicy
        let deviceKey = policy.requiresDevice ? deviceKeyProvider.locateDeviceKey(policy: policy) : nil
        if policy.requiresDevice, deviceKey == nil { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.enableBiometricUnlock(deviceKey: deviceKey, confirm: false)
            self.refreshBiometricAvailability()
        }
    }

    private func refreshBiometricBlob(deviceKey: Data?, vaultID: UUID) async {
        do {
            // No prompt: the user authenticated moments ago to get here, and
            // this only re-wraps an enrolment they already confirmed.
            try await enableBiometricUnlock(deviceKey: deviceKey, confirm: false)
        } catch {
            try? biometricFactor.disable(vaultID: vaultID)
        }
    }

    func disableDeviceFactor(password: String) async throws {
        guard let session else { throw VaultError.vaultNotFound }
        let header = session.header
        guard header.unlockPolicy.requiresDevice else { return }
        guard let deviceKey = deviceKeyProvider.locateDeviceKey(policy: header.unlockPolicy) else {
            throw VaultError.deviceKeyRequired
        }
        await session.flushPendingSaves()
        let current = session.unlocked
        let updated = try await Task.detached(priority: .userInitiated) {
            try DeviceKeyFactor.apply(
                to: current, password: password,
                currentDeviceKey: deviceKey,
                newPolicy: UnlockPolicy(), newDeviceKey: nil
            )
        }.value
        try await session.adopt(updated)
        // Remove the key file from the stick and restore a plain biometric blob.
        if let relPath = header.unlockPolicy.keyFileRelPath {
            for volume in deviceKeyProvider.candidateVolumes()
            where deviceKeyProvider.readKey(volumeURL: volume.url, relPath: relPath) == deviceKey {
                deviceKeyProvider.removeKey(volumeURL: volume.url, relPath: relPath)
            }
        }
        if biometricFactor.isEnabled(vaultID: updated.header.vaultID) {
            await refreshBiometricBlob(deviceKey: nil, vaultID: updated.header.vaultID)
        }
    }

    /// The connected stick's key when the current policy requires one —
    /// throws if it must be present but isn't.
    private func currentDeviceKeyIfRequired(header: VaultHeader) throws -> Data? {
        guard header.unlockPolicy.requiresDevice else { return nil }
        guard let key = deviceKeyProvider.locateDeviceKey(policy: header.unlockPolicy) else {
            throw VaultError.deviceKeyRequired
        }
        return key
    }

    // MARK: - iCloud mirror

    /// Copies the encrypted container to iCloud Drive after a change, when the
    /// user has asked for it. Failures are surfaced through `cloudBackupError`
    /// rather than thrown: a sync problem must never block saving the vault
    /// itself, but it must not be silent either — a backup you believe in and
    /// do not have is worse than none.
    private func mirrorToCloudIfEnabled(_ container: Data, settings: VaultSettings) {
        guard settings.cloudBackupEnabled else { return }
        do {
            try CloudBackupService.shared.write(container)
            cloudBackupError = nil
        } catch {
            cloudBackupError = error.localizedDescription
        }
    }

    /// Surfaced in Settings when an automatic iCloud copy fails.
    var cloudBackupError: String?

    /// Writes the current vault to iCloud Drive immediately.
    func backUpToCloudNow() throws {
        try CloudBackupService.shared.write(try exportVaultData())
        cloudBackupError = nil
    }

    // MARK: - Encrypted backup / restore

    /// The current vault as its encrypted container bytes.
    ///
    /// This is the SAME AES-GCM container that is written to disk — no new
    /// cryptography and no decryption. The file is openable only with the
    /// master password (and the USB key, if that factor is enabled), so it is
    /// safe to store anywhere. Sealed from the live session rather than read
    /// off disk so it is always the current, complete state with no write race.
    func exportVaultData() throws -> Data {
        guard let session else { throw VaultError.vaultNotFound }
        return try Vault.seal(session.unlocked)
    }

    /// Validates that `data` is a real SafeKey container and returns its header,
    /// so the UI can show creation date / provenance before the user commits to
    /// a destructive restore. Throws `.corruptVault` for anything else.
    func inspectBackup(_ data: Data) throws -> VaultHeader {
        try VaultFileFormat.decode(data).header
    }

    /// Replaces the vault on disk with an imported container, then locks so the
    /// user unlocks the imported vault with ITS OWN password.
    ///
    /// Destructive: the current vault file is overwritten. The self-destruct /
    /// attempt anchor and any biometric key belong to the OLD vault and no
    /// longer apply, so they are cleared — the imported vault starts with Touch
    /// ID un-enrolled until the user re-enables it. Refuses non-containers
    /// before touching anything on disk.
    func importVault(_ data: Data) async throws {
        let header = try VaultFileFormat.decode(data).header

        autoLock.stop()

        // Preserve the current vault so a bad restore is recoverable. The
        // imported payload cannot be authenticated here (that needs the
        // backup's password at unlock), so overwriting without a fallback
        // could otherwise destroy a working vault in exchange for a corrupt
        // one. The rescue copy is the same encrypted container, no less safe
        // than the vault it copies.
        if let current = try? await activeStore.read() {
            try? await activeStore.writeRescueCopy(current)
        }
        try await activeStore.write(data)

        anchors.clear()
        anchors.pin(container: data)
        biometricFactor.pruneStrategyMarkers(keeping: header.vaultID)
        biometricFactor.forgetStrategyMarker(vaultID: header.vaultID)

        demoState = nil
        lockedHeader = header
        tamperDetected = false
        state = .locked
        syncVolumeWatcher()
        refreshBiometricAvailability()
        refreshAttemptDisplay()
    }

    var session: VaultSession? {
        if case .unlocked(let session) = state { return session }
        return nil
    }

    func bootstrap() async {
        if DebugSupport.isDemo {
            await bootstrapDemo()
            return
        }
        if await store.vaultExists() {
            await refreshLockedHeader()
            state = .locked
            syncVolumeWatcher()
        } else {
            state = .noVault
        }
    }

    private func refreshLockedHeader() async {
        if let container = try? await activeStore.read(),
           let decoded = try? VaultFileFormat.decode(container) {
            lockedHeader = decoded.header
            tamperDetected = anchors.containerWasModified(container: container)
        } else {
            lockedHeader = nil
            tamperDetected = false
        }
        refreshAttemptDisplay()
        refreshBiometricAvailability()
    }

    /// DEBUG demo mode: throwaway temp-dir vault with sample data.
    private func bootstrapDemo() async {
        let demoStore = DebugSupport.demoStore()
        do {
            let (container, unlocked) = try await Task.detached {
                try Vault.create(password: DebugSupport.demoPassword, payload: DebugSupport.demoPayload(), iterations: 10_000)
            }.value
            try await demoStore.write(container)
            if DebugSupport.demoStartsLocked {
                demoState = (demoStore, container)
                state = .locked
            } else {
                state = .unlocked(VaultSession(unlocked: unlocked, store: demoStore))
            }
        } catch {
            state = .noVault
        }
    }

    /// Demo-mode locked state routes unlock attempts at the demo store.
    private var demoState: (VaultStore, Data)?

    func createVault(password: String) async throws {
        let (container, unlocked) = try await Self.createOffMain(password: password)
        try await store.write(container)
        // Fresh vault: drop any anchor left over from a previous one, then pin.
        anchors.clear()
        adoptUnlockedSession(unlocked, container: container, store: store)
    }

    func unlock(password: String) async throws {
        let activeStore = self.activeStore
        let container = try await activeStore.read()

        // A missing stick is not a wrong password: refuse before any KDF work
        // and never count it toward self-destruct.
        var deviceKeys: [Data?] = [nil]
        if let header = lockedHeader, header.unlockPolicy.requiresDevice {
            let found = deviceKeyProvider.locateDeviceKeys(policy: header.unlockPolicy)
            guard !found.isEmpty else { throw VaultError.deviceKeyRequired }
            deviceKeys = found.map { Optional($0) }
        }

        do {
            // Try every reachable device key before concluding the password is
            // wrong, so a stale or planted second stick cannot burn attempts.
            var unlocked: Vault.Unlocked?
            for candidate in deviceKeys {
                do {
                    unlocked = try await Self.unlockOffMain(container: container, password: password, deviceKey: candidate)
                    break
                } catch VaultError.wrongPassword {
                    continue
                }
            }
            guard let unlocked else { throw VaultError.wrongPassword }
            adoptUnlockedSession(unlocked, container: container, store: activeStore)
        } catch VaultError.wrongPassword {
            try await registerFailedAttempt(container: container)
            throw VaultError.wrongPassword
        } catch VaultError.tampered {
            // NOT a failed credential attempt, and it must never be counted as
            // one. `.tampered` means the DEK unwrapped — the password was
            // *correct* — and only the payload failed authentication.
            //
            // Counting it would hand an attacker the same forced-destruction
            // attack the anchor exists to stop: corrupt one byte of the sealed
            // payload, leave the header untouched so its digest still matches,
            // and the owner's correct password erases the vault after N tries.
            //
            // Reporting it distinctly is not a meaningful oracle: anyone
            // holding the file can already test passwords offline, so a
            // corrupted file tells them nothing a pristine copy would not.
            tamperDetected = true
            throw VaultError.tampered
        }
    }

    private func adoptUnlockedSession(_ unlocked: Vault.Unlocked, container: Data, store: VaultStore) {
        anchors.pin(container: container)
        tamperDetected = false
        refreshAttemptDisplay()
        // A successful unlock confirms the current vault is good, so any
        // pre-restore rescue copy is no longer needed.
        Task { await store.clearRescueCopy() }
        // Clear markers belonging to vaults that no longer exist.
        biometricFactor.pruneStrategyMarkers(keeping: unlocked.header.vaultID)
        reprovisionBiometricKeyIfEnabled()
        becomeUnlocked(VaultSession(unlocked: unlocked, store: store, onPersist: { [weak self] written, session in
            self?.anchors.pin(container: written)
            self?.refreshAttemptDisplay()
            self?.mirrorToCloudIfEnabled(written, settings: session.payload.settings)
        }))
    }

    /// Counts a failed *password* attempt and fires self-destruct only when the
    /// pinned policy says so **and** the on-disk header still matches the one
    /// pinned at the last successful unlock. Biometric failures and tamper
    /// errors never come through here.
    private func registerFailedAttempt(container: Data) async throws {
        if let header = try? VaultFileFormat.decode(container).header {
            lockedHeader = header
        }
        let outcome = anchors.registerFailure(
            currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: container)
        )
        refreshAttemptDisplay()
        if outcome.headerMismatch {
            // Someone rewrote the vault file. Never destroy on a header we did
            // not pin: otherwise an attacker who cannot open the vault could
            // arm self-destruct, corrupt the KDF salt, and let the owner's own
            // correct password erase everything.
            tamperDetected = true
            return
        }
        if outcome.shouldDestroy {
            await SelfDestruct.execute(
                store: activeStore,
                keychain: keychain,
                biometricFactor: biometricFactor
            )
            anchors.clear()
            lockedHeader = nil
            demoState = nil
            state = .noVault
            throw VaultError.vaultNotFound
        }
    }

    private func becomeUnlocked(_ session: VaultSession) {
        state = .unlocked(session)
        volumeWatcher.stop()
        startAutoLock(for: session)
    }

    private func startAutoLock(for session: VaultSession) {
        autoLock.start(settings: session.settings) { [weak self] in
            self?.lock()
        }
    }

    /// Re-applies auto-lock behavior after the user changes security settings.
    func refreshAutoLock() {
        if let session { startAutoLock(for: session) }
    }

    func lock() {
        guard case .unlocked(let session) = state else { return }
        autoLock.stop()
        ClipboardGuard.shared.clearIfStillOurs()
        lockedHeader = session.header
        state = .locked
        syncVolumeWatcher()
        // Re-check enrolment: Touch ID may have been switched on during this
        // session, and without this the cached value from launch persists and
        // the badge never appears.
        refreshBiometricAvailability()
        refreshAttemptDisplay()
    }

    // MARK: - Off-main crypto (PBKDF2 costs ~250 ms by design)

    private nonisolated static func createOffMain(password: String) async throws -> (Data, Vault.Unlocked) {
        try await Task.detached(priority: .userInitiated) {
            try Vault.create(password: password)
        }.value
    }

    private nonisolated static func unlockOffMain(container: Data, password: String, deviceKey: Data? = nil) async throws -> Vault.Unlocked {
        try await Task.detached(priority: .userInitiated) {
            try Vault.unlock(container: container, password: password, deviceKey: deviceKey)
        }.value
    }
}
