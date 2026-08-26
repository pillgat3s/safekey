import Foundation

/// Every failure the vault layer can produce. Equatable so callers and tests
/// can match on exact cases.
public enum VaultError: Error, Equatable, Sendable {
    /// The password (or password+device combination) failed to unwrap the DEK.
    /// GCM authentication on the wrapped DEK is the password verifier — there
    /// is deliberately no separate "password hash" to attack.
    case wrongPassword
    /// The container bytes are structurally invalid (bad magic, truncated,
    /// unparseable header).
    case corruptVault
    case unsupportedVersion(UInt16)
    case unsupportedKDF(String)
    /// The DEK unwrapped fine but payload authentication failed — the header
    /// or ciphertext was modified after sealing.
    case tampered
    /// The vault requires the USB security key and none was provided.
    case deviceKeyRequired
    /// A system crypto primitive failed (should never happen in practice).
    case cryptoFailure
    case vaultNotFound
}

/// Real sentences for the cases that reach an alert. Without this, a caller
/// showing `localizedDescription` prints "The operation couldn't be completed.
/// (SafeKeyCore.VaultError error 6.)" — which in a vault reads like data loss.
extension VaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongPassword:
            "Wrong password."
        case .corruptVault:
            "This file is damaged or is not a SafeKey vault."
        case .unsupportedVersion:
            "This vault was written by a newer version of SafeKey. Update the app to open it."
        case .unsupportedKDF:
            "This vault uses a protection method this version of SafeKey does not know."
        case .tampered:
            "The vault failed its integrity check — it was modified outside SafeKey."
        case .deviceKeyRequired:
            "This vault requires its USB security key."
        case .cryptoFailure:
            "A system encryption operation failed. Try again."
        case .vaultNotFound:
            "There is no vault on this device."
        }
    }
}
