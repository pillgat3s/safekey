import Foundation
import CryptoKit

/// High-level vault operations tying KDF + envelope + container together.
/// All functions are pure over `Data` — file I/O lives in `VaultStore`.
public enum Vault {
    public struct Unlocked: Sendable {
        public var header: VaultHeader
        public var payload: VaultPayload
        public let dek: SymmetricKey

        public init(header: VaultHeader, payload: VaultPayload, dek: SymmetricKey) {
            self.header = header
            self.payload = payload
            self.dek = dek
        }
    }

    // MARK: Create

    public static func create(
        password: String,
        payload: VaultPayload = VaultPayload(),
        iterations: Int? = nil
    ) throws -> (container: Data, unlocked: Unlocked) {
        let kdf = KDFParams(
            iterations: iterations ?? KeyDerivation.calibratedIterations(),
            salt: KeyDerivation.randomSalt()
        )
        let kek = try KeyDerivation.deriveKey(password: password, params: kdf)
        let dek = VaultCrypto.generateDEK()
        let header = VaultHeader(kdf: kdf, wrappedDEK: try VaultCrypto.wrapDEK(dek, under: kek))
        let unlocked = Unlocked(header: header, payload: payload, dek: dek)
        return (try seal(unlocked), unlocked)
    }

    // MARK: Unlock

    /// Password path (with optional USB device key when the policy requires it).
    public static func unlock(container: Data, password: String, deviceKey: Data? = nil) throws -> Unlocked {
        let decoded = try VaultFileFormat.decode(container)
        let kek = try kek(for: decoded.header, password: password, deviceKey: deviceKey)
        let dek = try VaultCrypto.unwrapDEK(decoded.header.wrappedDEK, under: kek)
        let payload = try VaultCrypto.openPayload(decoded.sealedPayload, dek: dek, aad: decoded.aad)
        return Unlocked(header: decoded.header, payload: payload, dek: dek)
    }

    /// Direct-DEK path, used by biometric unlock after the Keychain hands back
    /// the DEK.
    ///
    /// `deviceKeyWasPresented` records whether the caller actually found the
    /// USB key, and is checked against the policy as defence in depth against a
    /// coding mistake. Be clear about what it is not: the *real* enforcement of
    /// the second factor happens earlier, where the DEK is obtained. With the
    /// factor enabled the biometric Keychain blob is `AES-GCM(deviceKey, DEK)`,
    /// so without the stick there is no DEK to pass here in the first place.
    /// Anyone already holding the DEK can decrypt the payload by definition —
    /// no flag can change that — so callers must never rely on this check as a
    /// security boundary, and must never satisfy it by passing the policy's own
    /// value back in.
    public static func unlock(container: Data, dek: SymmetricKey, deviceKeyWasPresented: Bool = false) throws -> Unlocked {
        let decoded = try VaultFileFormat.decode(container)
        if decoded.header.unlockPolicy.requiresDevice, !deviceKeyWasPresented {
            throw VaultError.deviceKeyRequired
        }
        return try open(decoded: decoded, dek: dek)
    }

    /// Reopens a container with a DEK we already hold, with no policy gate.
    /// For verifying freshly sealed bytes before they replace a working vault.
    public static func validate(container: Data, dek: SymmetricKey) throws {
        _ = try open(decoded: try VaultFileFormat.decode(container), dek: dek)
    }

    private static func open(decoded: VaultFileFormat.Decoded, dek: SymmetricKey) throws -> Unlocked {
        let payload = try VaultCrypto.openPayload(decoded.sealedPayload, dek: dek, aad: decoded.aad)
        return Unlocked(header: decoded.header, payload: payload, dek: dek)
    }

    // MARK: Save

    /// Re-encodes the (possibly mutated) header and seals the payload with a
    /// fresh nonce. Callers persist the returned bytes via `VaultStore`.
    public static func seal(_ unlocked: Unlocked) throws -> Data {
        let headerJSON = try VaultJSON.encoder().encode(unlocked.header)
        let aad = VaultFileFormat.prefix(headerJSON: headerJSON)
        let sealed = try VaultCrypto.sealPayload(unlocked.payload, dek: unlocked.dek, aad: aad)
        return aad + sealed
    }

    // MARK: Password change

    /// Unwraps with the old credentials, re-wraps the same DEK under a KEK
    /// derived from the new password with a fresh salt. The DEK — and any
    /// biometric Keychain copy of it — stays valid.
    ///
    /// The iteration count is re-calibrated to this machine and never lowered.
    /// Without that, a vault created years ago (or on slower hardware) would
    /// keep its original work factor forever, which is precisely the parameter
    /// that bounds an offline attack on a copied file.
    public static func changePassword(
        container: Data,
        oldPassword: String,
        newPassword: String,
        deviceKey: Data? = nil
    ) throws -> Data {
        var unlocked = try unlock(container: container, password: oldPassword, deviceKey: deviceKey)
        let upgraded = max(unlocked.header.kdf.iterations, KeyDerivation.calibratedIterations())
        unlocked.header = try rewrappedHeader(
            unlocked.header,
            dek: unlocked.dek,
            password: newPassword,
            deviceKey: deviceKey,
            iterations: upgraded
        )
        return try seal(unlocked)
    }

    // MARK: Shared helpers

    /// Derives the effective KEK for a header: password KEK alone, or HKDF
    /// combined with the device key when the unlock policy requires it.
    static func kek(for header: VaultHeader, password: String, deviceKey: Data?) throws -> SymmetricKey {
        let passwordKEK = try KeyDerivation.deriveKey(password: password, params: header.kdf)
        guard header.unlockPolicy.requiresDevice else { return passwordKEK }
        guard let deviceKey, !deviceKey.isEmpty else { throw VaultError.deviceKeyRequired }
        return VaultCrypto.combinedKEK(passwordKEK: passwordKEK, deviceKey: deviceKey, salt: header.kdf.salt)
    }

    /// Builds a header whose wrappedDEK is re-wrapped for the given
    /// credentials with a fresh salt (iteration count is preserved).
    static func rewrappedHeader(
        _ header: VaultHeader,
        dek: SymmetricKey,
        password: String,
        deviceKey: Data?,
        iterations: Int? = nil
    ) throws -> VaultHeader {
        var newHeader = header
        newHeader.kdf = KDFParams(iterations: iterations ?? header.kdf.iterations, salt: KeyDerivation.randomSalt())
        let kek = try kek(for: newHeader, password: password, deviceKey: deviceKey)
        newHeader.wrappedDEK = try VaultCrypto.wrapDEK(dek, under: kek)
        return newHeader
    }
}
