import Foundation
import CryptoKit

/// Trusted, out-of-band record of what the vault looked like the last time it
/// was *successfully opened*.
///
/// Why this exists: the container header is plaintext and is only
/// authenticated by the payload's GCM tag — which is checked **after** the DEK
/// is unwrapped. On a failed unlock the DEK is never recovered, so nothing in
/// the header has been authenticated at that moment. Any destructive decision
/// (self-destruct) or security counter that reads the header on that path is
/// therefore attacker-controlled: someone with write access to the file, who
/// never learns the password, could arm self-destruct and flip a salt byte so
/// the owner's *correct* password erases the vault.
///
/// The anchor breaks that: policy and identity come from a record pinned at
/// the last successful unlock, and the vault is only ever destroyed when the
/// on-disk header still matches the one that was pinned.
public struct VaultAnchor: Codable, Sendable, Equatable {
    /// Vault identity as it appeared in an authenticated container.
    public var vaultID: UUID
    /// Self-destruct policy as it appeared in an authenticated container.
    public var selfDestruct: SelfDestructPolicy
    /// SHA-256 over the container prefix bytes (magic ‖ version ‖ len ‖ header
    /// JSON) — i.e. exactly the AAD.
    public var headerDigest: Data
    /// SHA-256 over the **whole** container as written to disk.
    ///
    /// Pinning the header alone is not enough: an attacker who corrupts only
    /// the sealed payload leaves the header digest matching, and every unlock
    /// then fails authentication. Covering the full file makes any external
    /// modification visible before a password is ever typed.
    public var containerDigest: Data
    /// Consecutive failed password attempts since the last successful unlock.
    public var failedAttempts: Int

    public init(
        vaultID: UUID,
        selfDestruct: SelfDestructPolicy,
        headerDigest: Data,
        containerDigest: Data,
        failedAttempts: Int = 0
    ) {
        self.vaultID = vaultID
        self.selfDestruct = selfDestruct
        self.headerDigest = headerDigest
        self.containerDigest = containerDigest
        self.failedAttempts = failedAttempts
    }

    public static func digest(of bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    /// Digest of a container's authenticated prefix, or nil if it will not parse.
    public static func headerDigest(ofContainer container: Data) -> Data? {
        guard let decoded = try? VaultFileFormat.decode(container) else { return nil }
        return digest(of: decoded.aad)
    }
}

/// Persists the anchor twice: a Keychain item and a file next to the vault.
///
/// The file mirror exists because ad-hoc re-signing changes the app's Keychain
/// identity and can orphan Keychain items. It is authenticated with an HMAC
/// key held only in the Keychain, so an attacker with filesystem access cannot
/// forge a high attempt count to force a wipe. If the HMAC key is unavailable
/// the mirror is simply distrusted.
///
/// Failure direction is deliberate throughout: when the anchor is missing or
/// untrusted, self-destruct is **disabled**, never triggered. Refusing to
/// destroy data is always the safer error.
public struct VaultAnchorStore: Sendable {
    public static let anchorAccount = "anchor.current"
    public static let macKeyAccount = "anchor.mackey"
    public static let mirrorFileName = "anchor.dat"

    let keychain: any SecretStore
    let directory: URL

    public init(keychain: any SecretStore, directory: URL) {
        self.keychain = keychain
        self.directory = directory
    }

    private var mirrorURL: URL { directory.appendingPathComponent(Self.mirrorFileName) }

    private struct SignedMirror: Codable {
        var anchor: VaultAnchor
        var mac: Data
    }

    // MARK: - MAC key

    /// Fetches the mirror's HMAC key, creating it on first use. Returns nil if
    /// the Keychain is unavailable — callers then distrust the mirror.
    private func macKey(createIfMissing: Bool) -> SymmetricKey? {
        if let existing = (try? keychain.read(account: Self.macKeyAccount)) ?? nil, existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        guard createIfMissing else { return nil }
        let fresh = KeyDerivation.randomBytes(count: 32)
        do {
            // Naming this app in the item's ACL is what lets a differently
            // signed build of it — a notarized release replacing a development
            // build — read the key back without a keychain prompt. Ignored on
            // iOS, where every item is scoped to its app already.
            try keychain.write(
                fresh,
                account: Self.macKeyAccount,
                accessibility: .afterFirstUnlockThisDeviceOnly,
                trustingThisApp: true
            )
        } catch {
            return nil
        }
        return SymmetricKey(data: fresh)
    }

    private func mac(_ anchor: VaultAnchor, key: SymmetricKey) -> Data? {
        guard let encoded = try? VaultJSON.encoder().encode(anchor) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: encoded, using: key))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) {
            difference |= x ^ y
        }
        return difference == 0
    }

    // MARK: - Load / save

    /// The trusted anchor, or nil when nothing trustworthy is stored.
    /// Takes the higher attempt count of the two stores so clearing one does
    /// not reset the anti-guessing clock.
    public func load() -> VaultAnchor? {
        let fromKeychain: VaultAnchor? = {
            guard let data = (try? keychain.read(account: Self.anchorAccount)) ?? nil else { return nil }
            return try? VaultJSON.decoder().decode(VaultAnchor.self, from: data)
        }()

        let fromMirror: VaultAnchor? = {
            guard
                let data = try? Data(contentsOf: mirrorURL),
                let signed = try? VaultJSON.decoder().decode(SignedMirror.self, from: data),
                let key = macKey(createIfMissing: false),
                let expected = mac(signed.anchor, key: key),
                // A forged mirror must not be usable to force a destructive
                // attempt count.
                Self.constantTimeEquals(expected, signed.mac)
            else { return nil }
            return signed.anchor
        }()

        switch (fromKeychain, fromMirror) {
        case (nil, nil):
            return nil
        case (let a?, nil):
            return a
        case (nil, let b?):
            return b
        case (let a?, let b?):
            // Same vault: keep the stricter (higher) attempt count. Different
            // vaults: trust the Keychain copy, which an attacker with only
            // filesystem access cannot write.
            guard a.vaultID == b.vaultID else { return a }
            var merged = a
            merged.failedAttempts = max(a.failedAttempts, b.failedAttempts)
            return merged
        }
    }

    public func save(_ anchor: VaultAnchor) {
        if let data = try? VaultJSON.encoder().encode(anchor) {
            try? keychain.write(
                data,
                account: Self.anchorAccount,
                accessibility: .afterFirstUnlockThisDeviceOnly,
                trustingThisApp: true
            )
        }
        guard
            let key = macKey(createIfMissing: true),
            let tag = mac(anchor, key: key),
            let payload = try? VaultJSON.encoder().encode(SignedMirror(anchor: anchor, mac: tag))
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? payload.write(to: mirrorURL, options: [.atomic])
        VaultStore.protectAtRest(mirrorURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mirrorURL.path)
    }

    public func clear() {
        try? keychain.delete(account: Self.anchorAccount)
        try? keychain.delete(account: Self.macKeyAccount)
        try? FileManager.default.removeItem(at: mirrorURL)
    }

    // MARK: - Operations

    /// Records a successful unlock or save: resets the counter and re-pins
    /// identity, policy, and digests from the exact container bytes on disk.
    public func pin(container: Data) {
        guard let decoded = try? VaultFileFormat.decode(container) else { return }
        save(VaultAnchor(
            vaultID: decoded.header.vaultID,
            selfDestruct: decoded.header.selfDestruct,
            headerDigest: VaultAnchor.digest(of: decoded.aad),
            containerDigest: VaultAnchor.digest(of: container),
            failedAttempts: 0
        ))
    }

    /// Counts a failed password attempt against the pinned identity and
    /// returns the decision.
    ///
    /// `currentHeaderDigest` is the digest of the header actually on disk right
    /// now. It must equal the pinned digest for destruction to be allowed —
    /// otherwise an attacker who rewrote the header could choose when the
    /// owner's vault dies.
    public func registerFailure(currentHeaderDigest: Data?) -> FailureOutcome {
        guard var anchor = load() else {
            // Never unlocked on this machine, or the anchor was removed. There
            // is no trustworthy policy to act on, so do not destroy anything.
            return FailureOutcome(attempts: 0, remaining: nil, shouldDestroy: false, headerMismatch: false)
        }
        // Saturating: an overflowed counter must not wrap to a low value.
        anchor.failedAttempts = anchor.failedAttempts < Int.max ? anchor.failedAttempts + 1 : Int.max
        save(anchor)

        let mismatch = currentHeaderDigest != anchor.headerDigest
        let armed = anchor.selfDestruct.enabled
        let reached = anchor.failedAttempts >= anchor.selfDestruct.maxAttempts
        return FailureOutcome(
            attempts: anchor.failedAttempts,
            remaining: armed ? max(0, anchor.selfDestruct.maxAttempts - anchor.failedAttempts) : nil,
            // Destroy only under the exact policy we pinned, on the exact
            // header we pinned.
            shouldDestroy: armed && reached && !mismatch,
            headerMismatch: mismatch
        )
    }

    public struct FailureOutcome: Sendable, Equatable {
        public let attempts: Int
        public let remaining: Int?
        public let shouldDestroy: Bool
        public let headerMismatch: Bool
    }

    /// Attempts left before self-destruct, for the unlock screen. Reads only
    /// pinned state — never the on-disk header.
    public func remainingAttempts() -> Int? {
        guard let anchor = load(), anchor.selfDestruct.enabled else { return nil }
        return max(0, anchor.selfDestruct.maxAttempts - anchor.failedAttempts)
    }

    /// True when the vault file differs from the one pinned at the last
    /// successful unlock or save — i.e. it was modified behind the app's back,
    /// in the header *or* the payload. Evaluated without any password input,
    /// so it leaks nothing to anyone watching.
    public func containerWasModified(container: Data) -> Bool {
        guard let anchor = load() else { return false }
        return VaultAnchor.digest(of: container) != anchor.containerDigest
    }
}
