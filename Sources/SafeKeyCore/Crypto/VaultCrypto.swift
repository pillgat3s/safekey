import Foundation
import CryptoKit

/// Envelope primitives. A random 256-bit DEK encrypts the payload; the DEK is
/// wrapped under a KEK derived from the password (optionally combined with the
/// USB device key). Password changes re-wrap the DEK without touching the
/// payload key.
public enum VaultCrypto {
    public static func generateDEK() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func wrapDEK(_ dek: SymmetricKey, under kek: SymmetricKey) throws -> Data {
        let dekData = dek.withUnsafeBytes { Data($0) }
        // No explicit nonce: AES.GCM.seal generates a fresh random one, and
        // `combined` is guaranteed non-nil for the default 12-byte nonce.
        guard let combined = try AES.GCM.seal(dekData, using: kek).combined else {
            throw VaultError.cryptoFailure
        }
        return combined
    }

    public static func unwrapDEK(_ wrapped: Data, under kek: SymmetricKey) throws -> SymmetricKey {
        guard
            let box = try? AES.GCM.SealedBox(combined: wrapped),
            let dekData = try? AES.GCM.open(box, using: kek)
        else {
            throw VaultError.wrongPassword
        }
        return SymmetricKey(data: dekData)
    }

    public static func sealPayload(_ payload: VaultPayload, dek: SymmetricKey, aad: Data) throws -> Data {
        let json = try VaultJSON.encoder().encode(payload)
        guard let combined = try AES.GCM.seal(json, using: dek, authenticating: aad).combined else {
            throw VaultError.cryptoFailure
        }
        return combined
    }

    public static func openPayload(_ sealed: Data, dek: SymmetricKey, aad: Data) throws -> VaultPayload {
        guard
            let box = try? AES.GCM.SealedBox(combined: sealed),
            let json = try? AES.GCM.open(box, using: dek, authenticating: aad)
        else {
            throw VaultError.tampered
        }
        return try VaultJSON.decoder().decode(VaultPayload.self, from: json)
    }

    /// Second-factor KEK: HKDF over passwordKEK ‖ deviceKey. Without the
    /// device key bytes the DEK cannot be unwrapped, regardless of password.
    public static func combinedKEK(passwordKEK: SymmetricKey, deviceKey: Data, salt: Data) -> SymmetricKey {
        var ikm = passwordKEK.withUnsafeBytes { Data($0) }
        ikm.append(deviceKey)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data("safekey-2f-v1".utf8),
            outputByteCount: 32
        )
    }
}
