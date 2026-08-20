import Foundation
import CryptoKit
import LocalAuthentication
import Security

public enum BiometricError: Error, Equatable, Sendable {
    case unavailable
    /// The user deliberately dismissed the prompt.
    case cancelled
    /// The system or the app tore the prompt down — deactivation, an
    /// `invalidate()`, a screen lock. Distinct from `.cancelled` because it
    /// carries no user intent: treating it as a dismissal would suppress the
    /// next automatic prompt for something the user never did.
    case interrupted
    case failed
    /// No biometric DEK item exists (never enabled, invalidated by fingerprint
    /// re-enrollment, or lost to an ad-hoc re-sign). Fall back to password.
    case notEnrolled
}

/// Biometric unlock: keeps a wrapped copy of the DEK in the Keychain behind
/// Touch ID. Two strategies, tried in order at enable time:
///
/// A. `accessControl` — data-protection Keychain item with
///    `SecAccessControl(.biometryCurrentSet)`: the system enforces biometry
///    at item-read time and re-enrollment invalidates the item.
/// B. `laContextGated` — plain Keychain item read only after an explicit
///    `LAContext.evaluatePolicy` succeeds. Weaker (the gate is app logic, not
///    the Keychain), used only when ad-hoc signing rejects strategy A
///    (errSecMissingEntitlement). The active strategy is reported in Settings.
///
/// Whatever the strategy, the stored blob is the *vault DEK* — or, when the
/// USB device factor is enabled, the DEK wrapped under the device key so
/// biometric unlock still requires the stick.
public struct BiometricFactor: Sendable {
    public enum Strategy: String, Sendable {
        case accessControl
        case laContextGated
    }

    public let service: String

    public init(service: String = "com.andri.safekey") {
        self.service = service
    }

    private func account(_ vaultID: UUID) -> String { "dek.bio.\(vaultID.uuidString)" }
    private func strategyKey(_ vaultID: UUID) -> String { "safekey.bioStrategy.\(vaultID.uuidString)" }

    public static func isBiometryAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public func activeStrategy(vaultID: UUID) -> Strategy? {
        UserDefaults.standard.string(forKey: strategyKey(vaultID)).flatMap(Strategy.init(rawValue:))
    }

    /// Whether a marker says biometric unlock was set up. Says nothing about
    /// whether the key is still readable — use `isEnrolled` for that.
    public func isEnabled(vaultID: UUID) -> Bool {
        activeStrategy(vaultID: vaultID) != nil
    }

    /// Whether the stored key actually still exists.
    ///
    /// The marker lives in UserDefaults and the key lives in the Keychain, and
    /// the two can diverge: reinstalling or re-signing the app changes its code
    /// identity and can orphan Keychain items, and deleting a vault leaves the
    /// marker behind. Trusting the marker alone makes the UI offer a Touch ID
    /// button that cannot work. Checked without requesting data, so this never
    /// raises a biometric prompt.
    public func isEnrolled(vaultID: UUID) -> Bool {
        resolvedStrategy(vaultID: vaultID) != nil
    }

    /// The strategy to actually use, with the **stored key as the source of
    /// truth** rather than the UserDefaults marker.
    ///
    /// The marker only records *which* scheme was used; the key itself is what
    /// matters. Requiring the marker meant that losing it — which my own error
    /// handling used to do on any failed read — hid a perfectly good key and
    /// made Touch ID look permanently broken. Now a missing marker is inferred
    /// from whichever keychain domain holds the item, and repaired in place.
    public func resolvedStrategy(vaultID: UUID) -> Strategy? {
        if let marker = activeStrategy(vaultID: vaultID), itemExists(vaultID: vaultID, strategy: marker) {
            return marker
        }
        for candidate in [Strategy.accessControl, .laContextGated]
        where itemExists(vaultID: vaultID, strategy: candidate) {
            UserDefaults.standard.set(candidate.rawValue, forKey: strategyKey(vaultID))
            return candidate
        }
        return nil
    }

    /// Existence check that never asks for data, so it raises no prompt.
    private func itemExists(vaultID: UUID, strategy: Strategy) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(vaultID),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if strategy == .accessControl {
            query[kSecUseDataProtectionKeychain as String] = true
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // Only genuine absence — or a domain this build cannot address at all —
        // counts as "no key here". Anything else means something is stored.
        return status != errSecItemNotFound && status != errSecMissingEntitlement
    }

    /// Drops a marker whose key has gone, so the UI stops offering Touch ID.
    public func forgetStrategyMarker(vaultID: UUID) {
        UserDefaults.standard.removeObject(forKey: strategyKey(vaultID))
    }

    /// Clears markers belonging to vaults other than this one — leftovers from
    /// vaults that were replaced or erased.
    public func pruneStrategyMarkers(keeping vaultID: UUID) {
        let keep = strategyKey(vaultID)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("safekey.bioStrategy.") && key != keep {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Enable / disable (caller must be unlocked)

    /// Stores the biometric copy of the key.
    ///
    /// `confirm` requires a successful Touch ID presentation first, which is
    /// what iOS does when you switch biometrics on. It proves the sensor
    /// actually works before the vault starts depending on it, and stops
    /// someone sitting at an already-unlocked vault quietly enrolling
    /// themselves. Pass `false` only when re-wrapping an enrolment the user
    /// just authenticated for by other means — a key rotation, say — where a
    /// second prompt would be noise rather than security.
    @discardableResult
    public func enable(secret: Data, vaultID: UUID, confirm: Bool = true) async throws -> Strategy {
        if confirm {
            try await evaluateBiometrics(reason: "enable Touch ID unlock for this vault")
        }
        try? disable(vaultID: vaultID)
        let strategy: Strategy
        do {
            try writeAccessControlled(secret, account: account(vaultID))
            strategy = .accessControl
        } catch KeychainService.KeychainError.unexpectedStatus(let status)
            where status == errSecMissingEntitlement || status == errSecParam {
            // Ad-hoc signed builds can't use the data-protection keychain.
            try KeychainService(service: service).write(
                secret,
                account: account(vaultID),
                accessibility: .whenUnlockedThisDeviceOnly,
                // Without this the item only trusts the exact binary that wrote
                // it, so every rebuild triggers the login-keychain password
                // prompt and a dismissed prompt looks like a lost key.
                trustingThisApp: true
            )
            strategy = .laContextGated
        }
        UserDefaults.standard.set(strategy.rawValue, forKey: strategyKey(vaultID))
        return strategy
    }

    /// Removes every stored strategy marker. Used by self-destruct: the
    /// markers live in UserDefaults, which `keychain.deleteAll()` cannot reach,
    /// and a stale marker would make the app claim biometric unlock is
    /// available after the vault is gone.
    public func forgetAllStrategyMarkers() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("safekey.bioStrategy.") {
            defaults.removeObject(forKey: key)
        }
    }

    public func disable(vaultID: UUID) throws {
        UserDefaults.standard.removeObject(forKey: strategyKey(vaultID))
        // Delete both possible item flavors.
        for useDataProtection in [true, false] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account(vaultID),
            ]
            if useDataProtection {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Unlock

    /// Prompts Touch ID and returns the stored secret blob.
    /// `context` lets the caller supply the same `LAContext` that is bound to an
    /// on-screen `LAAuthenticationView`, which is what makes the prompt render
    /// inside the app's window instead of as a floating panel. Passing nil
    /// falls back to a private context and the system panel.
    /// `LAContext` is not `Sendable`, so the caller's context is handed over on
    /// the main actor rather than crossing an isolation boundary.
    @MainActor
    public func obtainSecret(
        vaultID: UUID,
        reason: String,
        context: LAContext? = nil
    ) async throws -> Data {
        guard let strategy = resolvedStrategy(vaultID: vaultID) else { throw BiometricError.notEnrolled }
        guard Self.isBiometryAvailable() else { throw BiometricError.unavailable }
        switch strategy {
        case .accessControl:
            return try await readAccessControlled(account: account(vaultID), reason: reason)
        case .laContextGated:
            try await evaluateBiometrics(reason: reason, context: context)
            do {
                guard let data = try KeychainService(service: service).read(account: account(vaultID)) else {
                    throw BiometricError.notEnrolled
                }
                return data
            } catch let error as KeychainService.KeychainError {
                // Distinguish "the key is gone" from "the read was refused".
                // Only the former means enrolment is dead; a refused or
                // cancelled ACL prompt must not discard a perfectly good key.
                if case .unexpectedStatus(let status) = error, status == errSecItemNotFound {
                    throw BiometricError.notEnrolled
                }
                throw BiometricError.failed
            }
        }
    }

    // MARK: - Strategy A internals

    private func writeAccessControlled(_ data: Data, account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessControlError
        ) else {
            throw KeychainService.KeychainError.unexpectedStatus(errSecParam)
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = accessControl
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainService.KeychainError.unexpectedStatus(status)
        }
    }

    private func readAccessControlled(account: String, reason: String) async throws -> Data {
        let service = self.service
        return try await withCheckedThrowingContinuation { continuation in
            // Keychain biometric evaluation blocks; keep it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseDataProtectionKeychain as String: true,
                    kSecUseAuthenticationContext as String: context,
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    if let data = result as? Data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: BiometricError.failed)
                    }
                case errSecItemNotFound:
                    continuation.resume(throwing: BiometricError.notEnrolled)
                case errSecUserCanceled:
                    continuation.resume(throwing: BiometricError.cancelled)
                case errSecAuthFailed:
                    continuation.resume(throwing: BiometricError.failed)
                default:
                    continuation.resume(throwing: BiometricError.failed)
                }
            }
        }
    }

    // MARK: - Strategy B internals

    /// Runs on the main actor deliberately. macOS decides where to put the
    /// biometric prompt based on the calling app's active window; started from
    /// a background executor there is no window context to attach to and the
    /// system falls back to a free-floating panel instead of a sheet on our
    /// own window.
    @MainActor
    private func evaluateBiometrics(reason: String, context suppliedContext: LAContext? = nil) async throws {
        let context = suppliedContext ?? LAContext()
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            guard success else { throw BiometricError.failed }
        } catch let error as LAError {
            switch error.code {
            case .userCancel:
                throw BiometricError.cancelled
            case .systemCancel, .appCancel:
                throw BiometricError.interrupted
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                throw BiometricError.unavailable
            default:
                throw BiometricError.failed
            }
        }
    }
}
