import Foundation
import CryptoKit

/// Enable/disable operations for the USB security-key factor. The factor is
/// cryptographic: with it enabled, the DEK is wrapped under
/// HKDF(passwordKEK ‖ deviceKey) — password alone cannot unwrap it.
public enum DeviceKeyFactor {
    public static func generateDeviceKey() -> Data {
        KeyDerivation.randomBytes(count: VolumeDeviceKeyProvider.deviceKeyByteCount)
    }

    /// Applies a new unlock policy after verifying the current credentials,
    /// **rotating the DEK** in the process. Returns the updated unlocked state
    /// — caller seals and persists. `currentDeviceKey` must be provided when
    /// the factor is currently enabled (you cannot reconfigure without the
    /// stick).
    ///
    /// Rotation is what makes enabling the second factor mean anything. If the
    /// DEK were merely re-wrapped, anyone holding an *older* copy of the
    /// container (a Time Machine snapshot, a synced folder, a disk image) plus
    /// the password could recover that same DEK from the old copy and use it to
    /// open the current, supposedly two-factor container — because the AAD
    /// binds the header to a given DEK, it does not bind the DEK to a policy.
    /// A fresh DEK never existed in any earlier copy, so secrets written after
    /// the change are protected even against a holder of an old backup.
    ///
    /// Callers must refresh any stored biometric copy of the DEK afterwards;
    /// the previous copy is dead.
    public static func apply(
        to unlocked: Vault.Unlocked,
        password: String,
        currentDeviceKey: Data?,
        newPolicy: UnlockPolicy,
        newDeviceKey: Data?
    ) throws -> Vault.Unlocked {
        // Verify the password (and current stick) against the current header
        // so a typo can't produce a vault nobody can open.
        let currentKEK = try Vault.kek(for: unlocked.header, password: password, deviceKey: currentDeviceKey)
        let verified = try VaultCrypto.unwrapDEK(unlocked.header.wrappedDEK, under: currentKEK)
        guard verified.withUnsafeBytes({ Data($0) }) == unlocked.dek.withUnsafeBytes({ Data($0) }) else {
            throw VaultError.wrongPassword
        }
        if newPolicy.requiresDevice, newDeviceKey == nil {
            throw VaultError.deviceKeyRequired
        }

        let rotatedDEK = VaultCrypto.generateDEK()
        var header = unlocked.header
        header.unlockPolicy = newPolicy
        header.kdf = KDFParams(iterations: header.kdf.iterations, salt: KeyDerivation.randomSalt())
        let newKEK = try Vault.kek(for: header, password: password, deviceKey: newDeviceKey)
        header.wrappedDEK = try VaultCrypto.wrapDEK(rotatedDEK, under: newKEK)

        // Vault.seal re-encrypts the payload under the rotated key.
        return Vault.Unlocked(header: header, payload: unlocked.payload, dek: rotatedDEK)
    }
}
