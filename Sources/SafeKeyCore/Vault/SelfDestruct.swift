import Foundation

public enum SelfDestruct {
    /// Crypto-shredding: destroy every wrapped copy of the DEK, then the
    /// container.
    ///
    /// Order matters — Keychain first (it holds the biometric DEK copy and the
    /// anchor), then the vault file and its directory. Returns false if any
    /// step failed: a shred that silently did nothing is worse than one that
    /// reports an error, because the caller tells the user their data is gone.
    @discardableResult
    public static func execute(
        store: VaultStore,
        keychain: any SecretStore,
        biometricFactor: BiometricFactor? = nil
    ) async -> Bool {
        var succeeded = true

        // Biometric strategy markers live in UserDefaults, not the Keychain.
        biometricFactor?.forgetAllStrategyMarkers()

        do {
            try keychain.deleteAll()
        } catch {
            succeeded = false
        }
        do {
            try await store.destroy()
        } catch {
            succeeded = false
        }
        return succeeded
    }

    /// Policy evaluation. Kept as a pure function so the decision is testable
    /// in isolation; callers must source `policy` from `VaultAnchor`, never
    /// from a freshly decoded (unauthenticated) header.
    public static func shouldTrigger(policy: SelfDestructPolicy, failedCount: Int) -> Bool {
        policy.enabled && failedCount >= policy.maxAttempts
    }
}
