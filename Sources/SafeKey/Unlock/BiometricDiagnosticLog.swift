import Foundation
import LocalAuthentication
import SafeKeyCore

/// Records what actually happened during a biometric unlock attempt.
///
/// Touch ID cannot be exercised from a script — no automated check can press a
/// sensor — so the only way to see where the chain breaks is to have the app
/// write it down. Errors only, never key material.
enum BiometricDiagnosticLog {
    static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SafeKey/biometric-log.txt")

    /// A precise, human-readable name for an error, so the on-screen message
    /// distinguishes causes that used to look identical.
    static func describe(_ error: any Error) -> String {
        if let error = error as? BiometricError {
            switch error {
            case .unavailable: return "biometrics unavailable"
            case .cancelled: return "cancelled by user"
            case .interrupted: return "interrupted by system"
            case .failed: return "authentication failed"
            case .notEnrolled: return "no stored key (not enrolled)"
            }
        }
        if let error = error as? VaultError {
            switch error {
            case .wrongPassword: return "stored key rejected (wrong key)"
            case .tampered: return "vault authentication failed (stale or wrong stored key)"
            case .corruptVault: return "vault file unreadable"
            case .deviceKeyRequired: return "USB security key required"
            case .vaultNotFound: return "vault file missing"
            case .unsupportedVersion(let v): return "unsupported vault version \(v)"
            case .unsupportedKDF(let k): return "unsupported KDF \(k)"
            case .cryptoFailure: return "crypto failure"
            }
        }
        if let error = error as? LAError {
            return "LAError \(error.code.rawValue): \(error.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    /// Debug builds only. A release build must not keep a running record of
    /// when the vault was opened and how — that is behavioural data the user
    /// never asked to have written down, growing without bound in a file next
    /// to the vault. `describe` stays available: the on-screen error text
    /// depends on it.
    static func record(_ stage: String, error: (any Error)? = nil) {
        #if DEBUG
        var line = "\(Date().formatted(date: .omitted, time: .standard))  \(stage)"
        if let error {
            line += " — \(describe(error))"
        }
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
