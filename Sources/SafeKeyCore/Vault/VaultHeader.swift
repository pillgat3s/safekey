import Foundation

public struct SelfDestructPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var maxAttempts: Int

    public init(enabled: Bool = false, maxAttempts: Int = 5) {
        self.enabled = enabled
        self.maxAttempts = maxAttempts
    }

    /// The choices the UI offers. Fewer than three and an ordinary typo streak
    /// erases the vault; more than ten and the limit stops bounding guesses in
    /// any meaningful way.
    public static let attemptRange = 3...10
}

/// Which factors are required to unlock. The volume fields are detection
/// hints for the UI only — the security comes from the device key bytes
/// being an input to the KEK derivation.
public struct UnlockPolicy: Codable, Sendable, Equatable {
    public var requiresDevice: Bool
    public var volumeUUID: String?
    public var volumeName: String?
    public var keyFileRelPath: String?

    public init(requiresDevice: Bool = false, volumeUUID: String? = nil, volumeName: String? = nil, keyFileRelPath: String? = nil) {
        self.requiresDevice = requiresDevice
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.keyFileRelPath = keyFileRelPath
    }
}

/// Plaintext (but authenticated) vault metadata. Readable while locked so the
/// app can derive the KEK and show unlock UI; any modification is caught by
/// the payload's GCM tag because the header bytes are the AAD.
public struct VaultHeader: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var vaultID: UUID
    public var createdAt: Date
    public var kdf: KDFParams
    /// AES-GCM combined box (nonce ‖ ct ‖ tag) of the 32-byte DEK under the KEK.
    public var wrappedDEK: Data
    public var selfDestruct: SelfDestructPolicy
    public var unlockPolicy: UnlockPolicy

    public init(
        formatVersion: Int = 1,
        vaultID: UUID = UUID(),
        createdAt: Date = .vaultNow(),
        kdf: KDFParams,
        wrappedDEK: Data,
        selfDestruct: SelfDestructPolicy = SelfDestructPolicy(),
        unlockPolicy: UnlockPolicy = UnlockPolicy()
    ) {
        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.createdAt = createdAt
        self.kdf = kdf
        self.wrappedDEK = wrappedDEK
        self.selfDestruct = selfDestruct
        self.unlockPolicy = unlockPolicy
    }
}
