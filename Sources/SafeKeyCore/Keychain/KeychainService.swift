import Foundation
import Security

public enum KeychainAccessibility: Sendable {
    /// For low-sensitivity state (the failed-attempt counter).
    case afterFirstUnlockThisDeviceOnly
    /// For key material.
    case whenUnlockedThisDeviceOnly

    var secValue: CFString {
        switch self {
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

/// Abstraction over the Keychain so tests can use an in-memory fake.
/// IMPORTANT design rule: every Keychain item is a *cache*. Ad-hoc re-signing
/// changes the app's Keychain identity, so reads can fail at any time — no
/// correctness may depend on a Keychain read succeeding.
public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String, accessibility: KeychainAccessibility, trustingThisApp: Bool) throws
    func delete(account: String) throws
    /// Removes every item this app owns under its service name.
    func deleteAll() throws
}

public extension SecretStore {
    func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws {
        try write(data, account: account, accessibility: accessibility, trustingThisApp: false)
    }
}

public struct KeychainService: SecretStore {
    public let service: String

    public init(service: String = "com.andri.safekey") {
        self.service = service
    }

    public enum KeychainError: Error, Equatable, Sendable {
        case unexpectedStatus(OSStatus)
    }

    private func baseQuery(account: String?, dataProtection: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func write(
        _ data: Data,
        account: String,
        accessibility: KeychainAccessibility,
        trustingThisApp: Bool = false
    ) throws {
        try? delete(account: account)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data

        // An item created without an explicit ACL only trusts whichever binary
        // wrote it, so macOS demands the login-keychain password whenever the
        // app's signature changes. Naming this app as a trusted application
        // means it can read its own item back without prompting.
        //
        // iOS has no keychain ACLs — the system scopes every item to the app
        // that wrote it — so there the accessibility attribute is always right
        // and `SecAccess` does not even exist.
        #if os(macOS)
        if trustingThisApp, let access = Self.accessTrustingThisApp() {
            attributes[kSecAttrAccess as String] = access
        } else {
            // `kSecAttrAccess` and `kSecAttrAccessible` are mutually exclusive.
            attributes[kSecAttrAccessible as String] = accessibility.secValue
        }
        #else
        attributes[kSecAttrAccessible as String] = accessibility.secValue
        #endif

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// A keychain ACL naming the running application as trusted.
    ///
    /// `SecAccessCreate` is long-deprecated but is the only way to set an ACL
    /// on a login-keychain item, and the data-protection keychain (which would
    /// avoid this entirely) needs an `application-identifier` entitlement that
    /// requires a provisioning profile.
    #if os(macOS)
    private static func accessTrustingThisApp() -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted
        else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("SafeKey" as CFString, [trusted] as CFArray, &access) == errSecSuccess else {
            return nil
        }
        return access
    }
    #endif

    public func delete(account: String) throws {
        try deleteBothDomains(account: account)
    }

    public func deleteAll() throws {
        try deleteBothDomains(account: nil)
    }

    /// Items land in one of two Keychain domains: `BiometricFactor` writes the
    /// DEK copy to the **data-protection** keychain, while everything else uses
    /// the legacy file keychain. A query without `kSecUseDataProtectionKeychain`
    /// cannot match a data-protection item, so deleting from one domain alone
    /// would leave a usable, biometry-gated copy of the vault key behind after
    /// a self-destruct. Always delete from both.
    private func deleteBothDomains(account: String?) throws {
        var firstError: OSStatus?
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                continue
            case errSecMissingEntitlement where dataProtection:
                // An ad-hoc signed build has no application-identifier, so the
                // data-protection keychain is unreachable — meaning nothing of
                // ours can be stored there and there is nothing to delete.
                // Treating that as a failure made every delete throw, which in
                // turn broke enabling Touch ID.
                continue
            default:
                if firstError == nil { firstError = status }
            }
        }
        if let firstError {
            throw KeychainError.unexpectedStatus(firstError)
        }
    }
}
