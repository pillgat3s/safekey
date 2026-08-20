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
