import Foundation
import CryptoKit

/// An unlock factor produces the vault DEK from a locked container.
///
/// Built-in factors: password (`Vault.unlock(container:password:)`), password
/// + USB device key (same call with `deviceKey:`), and biometrics
/// (`BiometricFactor`, which fetches a wrapped DEK copy from the Keychain).
/// New factors — e.g. a smart-card or network HSM — conform to this protocol
/// and either derive a KEK input (like the device key) or produce the DEK
/// directly (like biometrics).
public protocol UnlockFactor: Sendable {
    var factorID: String { get }
    var displayName: String { get }
    /// Returns the DEK, or throws a `VaultError` describing why this factor
    /// cannot unlock right now.
    func obtainDEK(container: Data) async throws -> SymmetricKey
}

/// The baseline factor: master password (plus device key when policy requires).
public struct PasswordFactor: UnlockFactor {
    public let factorID = "password"
    public let displayName = "Master Password"
    let password: String
    let deviceKey: Data?

    public init(password: String, deviceKey: Data? = nil) {
        self.password = password
        self.deviceKey = deviceKey
    }

    public func obtainDEK(container: Data) async throws -> SymmetricKey {
        try Vault.unlock(container: container, password: password, deviceKey: deviceKey).dek
    }
}
