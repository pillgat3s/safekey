import XCTest
import CryptoKit
@testable import SafeKeyCore

/// Regression tests for the findings of the adversarial audit. Each test
/// reproduces a real attack that used to work and asserts it now fails.
///
/// Threat model throughout: the attacker can READ and WRITE `vault.safekey`
/// and the files beside it, and never learns the master password.
final class TamperAttackTests: XCTestCase {
    private let password = "correct horse battery staple"
    private var tempDir: URL!
    private var keychain: FakeSecretStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TamperTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        keychain = FakeSecretStore()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private var anchors: VaultAnchorStore {
        VaultAnchorStore(keychain: keychain, directory: tempDir)
    }

    /// Builds a vault, pins it as if it had been unlocked, and returns the container.
    private func makeArmedVault(maxAttempts: Int = 3) throws -> Data {
        var (container, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        unlocked.header.selfDestruct = SelfDestructPolicy(enabled: true, maxAttempts: maxAttempts)
        container = try Vault.seal(unlocked)
        anchors.pin(container: container)
        return container
    }

    /// Rewrites the header of a container, keeping the original sealed payload.
    private func rewriteHeader(_ container: Data, _ mutate: (inout VaultHeader) -> Void) throws -> Data {
        let decoded = try VaultFileFormat.decode(container)
        var header = decoded.header
        mutate(&header)
        let json = try VaultJSON.encoder().encode(header)
        return VaultFileFormat.encode(headerJSON: json, sealedPayload: decoded.sealedPayload)
    }

    // MARK: - C1: forced destruction

    /// THE CRITICAL ONE. Attacker arms self-destruct with maxAttempts: 1 and
    /// corrupts the salt so the owner's CORRECT password fails to unwrap.
    /// Previously: the next correct password erased the vault. Now: the
    /// mismatch against the pinned header must veto destruction.
    func testAttackerCannotForceSelfDestructByArmingTamperedHeader() throws {
        let container = try makeArmedVault(maxAttempts: 5)

        let forged = try rewriteHeader(container) { header in
            header.selfDestruct = SelfDestructPolicy(enabled: true, maxAttempts: 1)
            var salt = header.kdf.salt
            salt[0] ^= 0xFF
            header.kdf = KDFParams(iterations: header.kdf.iterations, salt: salt)
        }

        // The owner types the correct password; it cannot unwrap the corrupted header.
        XCTAssertThrowsError(try Vault.unlock(container: forged, password: password))

        let outcome = anchors.registerFailure(currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: forged))
        XCTAssertTrue(outcome.headerMismatch, "modified header must be detected")
        XCTAssertFalse(outcome.shouldDestroy, "must never destroy on a header we did not pin")
    }

    /// The attacker's other direction: silently DISARM the owner's
    /// self-destruct by editing the header. The pinned policy must win.
    func testAttackerCannotDisarmSelfDestructByEditingHeader() throws {
        let container = try makeArmedVault(maxAttempts: 2)
        let disarmed = try rewriteHeader(container) { header in
            header.selfDestruct = SelfDestructPolicy(enabled: false, maxAttempts: 999)
        }
        // Header now claims "disarmed", but the attacker also has to leave the
        // header unmodified for guesses to count — either way they lose:
        // mismatched header => no destruction but also full tamper visibility.
        let outcome = anchors.registerFailure(currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: disarmed))
        XCTAssertTrue(outcome.headerMismatch)

        // On the *pristine* file the pinned policy still applies and still fires.
        let digest = VaultAnchor.headerDigest(ofContainer: container)
        let second = anchors.registerFailure(currentHeaderDigest: digest)
        XCTAssertFalse(second.headerMismatch)
        XCTAssertTrue(second.shouldDestroy, "pinned policy (2 attempts) governs, not the header")
    }

    /// Self-destruct must still work normally on an untampered vault.
    func testSelfDestructStillFiresOnPristineVault() throws {
        let container = try makeArmedVault(maxAttempts: 3)
        let digest = VaultAnchor.headerDigest(ofContainer: container)
        XCTAssertFalse(anchors.registerFailure(currentHeaderDigest: digest).shouldDestroy)
        XCTAssertFalse(anchors.registerFailure(currentHeaderDigest: digest).shouldDestroy)
        let third = anchors.registerFailure(currentHeaderDigest: digest)
        XCTAssertTrue(third.shouldDestroy)
        XCTAssertEqual(third.attempts, 3)
    }

    /// With no pinned anchor (vault never opened on this machine) nothing may
    /// be destroyed — fail safe.
    func testNoAnchorMeansNoDestruction() throws {
        _ = try Vault.create(password: password, iterations: testIterations)
        let outcome = anchors.registerFailure(currentHeaderDigest: Data(repeating: 0, count: 32))
        XCTAssertFalse(outcome.shouldDestroy)
        XCTAssertNil(anchors.remainingAttempts())
    }

    /// The payload-only variant of the forced-destruction attack, and the one
    /// that survived the first round of fixes.
    ///
    /// Corrupting the sealed payload while leaving the header untouched keeps
    /// the header digest matching, so the digest gate does not fire. What stops
    /// it is that the resulting error is `.tampered` — the DEK unwrapped, so
    /// the password was CORRECT — and a correct password must never be counted
    /// as a failed attempt.
    func testPayloadCorruptionIsNotAFailedPasswordAttempt() throws {
        let container = try makeArmedVault(maxAttempts: 2)

        var corrupted = container
        corrupted[corrupted.count - 5] ^= 0x01

        // The header is untouched, so the digest gate alone would NOT catch this.
        XCTAssertEqual(
            VaultAnchor.headerDigest(ofContainer: corrupted),
            VaultAnchor.headerDigest(ofContainer: container),
            "precondition: header digest still matches, so only the error kind protects us"
        )
        // ...but the full-container digest does catch it, without a password.
        XCTAssertTrue(anchors.containerWasModified(container: corrupted))

        // The correct password now yields .tampered, never .wrongPassword.
        XCTAssertThrowsError(try Vault.unlock(container: corrupted, password: password)) {
            XCTAssertEqual($0 as? VaultError, .tampered)
        }
        // And the counter must not have moved: no amount of correct-password
        // entry against a corrupted payload may erase the vault.
        XCTAssertEqual(anchors.load()?.failedAttempts, 0)
        XCTAssertEqual(anchors.remainingAttempts(), 2)
    }

    /// A wrong password against a corrupted payload still fails as a wrong
    /// password (the DEK never unwraps), so genuine guessing is still counted.
    func testWrongPasswordAgainstCorruptedPayloadStillCounts() throws {
        let container = try makeArmedVault(maxAttempts: 3)
        var corrupted = container
        corrupted[corrupted.count - 5] ^= 0x01

        XCTAssertThrowsError(try Vault.unlock(container: corrupted, password: "not the password")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    // MARK: - C2: counter evasion

    /// Previously the counter was keyed on the header's vaultID, so rewriting
    /// that UUID before every guess reset the count and gave unlimited tries.
    func testRewritingVaultIDDoesNotResetTheCounter() throws {
        let container = try makeArmedVault(maxAttempts: 3)

        // Attacker rewrites vaultID before each guess.
        for _ in 0..<2 {
            let reidentified = try rewriteHeader(container) { $0.vaultID = UUID() }
            _ = anchors.registerFailure(currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: reidentified))
        }
        // The counter is keyed to the pinned identity, so it kept counting.
        XCTAssertEqual(anchors.load()?.failedAttempts, 2)

        let outcome = anchors.registerFailure(currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: container))
        XCTAssertTrue(outcome.shouldDestroy, "third guess must hit the pinned threshold")
    }

    /// The file mirror is HMAC-authenticated: an attacker who writes a huge
    /// attempt count into it must not be able to pre-arm the owner's next typo.
    func testForgedMirrorCannotForceDestruction() throws {
        let container = try makeArmedVault(maxAttempts: 5)
        _ = anchors.registerFailure(currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: container))

        // Forge the mirror with a count past the threshold and a bogus MAC.
        let mirrorURL = tempDir.appendingPathComponent(VaultAnchorStore.mirrorFileName)
        let forgedAnchor = VaultAnchor(
            vaultID: try VaultFileFormat.decode(container).header.vaultID,
            selfDestruct: SelfDestructPolicy(enabled: true, maxAttempts: 5),
            headerDigest: VaultAnchor.headerDigest(ofContainer: container)!,
            containerDigest: VaultAnchor.digest(of: container),
            failedAttempts: 99
        )
        struct Forged: Codable { var anchor: VaultAnchor; var mac: Data }
        let payload = try VaultJSON.encoder().encode(Forged(anchor: forgedAnchor, mac: Data(repeating: 0xAA, count: 32)))
        try payload.write(to: mirrorURL)

        // The forged count must be ignored; only the Keychain copy counts.
        XCTAssertEqual(anchors.load()?.failedAttempts, 1)
        let outcome = anchors.registerFailure(currentHeaderDigest: VaultAnchor.headerDigest(ofContainer: container))
        XCTAssertFalse(outcome.shouldDestroy)
        XCTAssertEqual(outcome.attempts, 2)
    }

    /// Deleting the Keychain anchor must not reset the count — that is what
    /// the (authenticated) mirror is for.
    func testCountSurvivesKeychainLossViaAuthenticatedMirror() throws {
        let container = try makeArmedVault(maxAttempts: 4)
        let digest = VaultAnchor.headerDigest(ofContainer: container)
        _ = anchors.registerFailure(currentHeaderDigest: digest)
        _ = anchors.registerFailure(currentHeaderDigest: digest)
        XCTAssertEqual(anchors.load()?.failedAttempts, 2)

        // Lose only the anchor record; the MAC key remains.
        try keychain.delete(account: VaultAnchorStore.anchorAccount)
        XCTAssertEqual(anchors.load()?.failedAttempts, 2, "mirror must carry the count")
    }

    // MARK: - C5: KDF parameter abuse

    /// A huge iteration count used to trap the UInt32 conversion and crash the
    /// process on every launch — a permanent brick from one file edit.
    func testAbsurdIterationCountIsRejectedNotTrapped() throws {
        let container = try makeArmedVault()
        let bricked = try rewriteHeader(container) { header in
            header.kdf = KDFParams(iterations: 5_000_000_000, salt: header.kdf.salt)
        }
        XCTAssertThrowsError(try Vault.unlock(container: bricked, password: password)) {
            XCTAssertEqual($0 as? VaultError, .corruptVault)
        }
    }

    /// Structurally invalid KDF parameters must not masquerade as a bad
    /// credential — otherwise they are a self-destruct trigger.
    func testInvalidKDFParamsReportCorruptionNotWrongPassword() throws {
        let container = try makeArmedVault()
        for mutation in [
            { (h: inout VaultHeader) in h.kdf = KDFParams(iterations: 0, salt: h.kdf.salt) },
            { (h: inout VaultHeader) in h.kdf = KDFParams(iterations: h.kdf.iterations, salt: Data()) },
            { (h: inout VaultHeader) in h.kdf = KDFParams(iterations: -5, salt: h.kdf.salt) },
        ] {
            let broken = try rewriteHeader(container, mutation)
            XCTAssertThrowsError(try Vault.unlock(container: broken, password: password)) {
                XCTAssertEqual($0 as? VaultError, .corruptVault)
            }
        }
    }

    // MARK: - C4: DEK rotation

    /// An old pre-2FA copy of the vault, plus the password, used to yield a DEK
    /// that still opened the current two-factor container. Rotation kills that.
    func testEnablingDeviceFactorRotatesDEKSoOldBackupsAreUseless() throws {
        let (oldContainer, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)

        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let policy = UnlockPolicy(requiresDevice: true, volumeUUID: "U", volumeName: "KEY", keyFileRelPath: VolumeDeviceKeyProvider.defaultKeyRelPath)
        let twoFactor = try DeviceKeyFactor.apply(
            to: unlocked, password: password,
            currentDeviceKey: nil, newPolicy: policy, newDeviceKey: deviceKey
        )
        let newContainer = try Vault.seal(twoFactor)

        // Attacker recovers the OLD DEK from the OLD copy using the password.
        let oldDEK = try Vault.unlock(container: oldContainer, password: password).dek
        XCTAssertNotEqual(
            oldDEK.withUnsafeBytes { Data($0) },
            twoFactor.dek.withUnsafeBytes { Data($0) },
            "DEK must be rotated when the unlock policy changes"
        )
        // That old DEK must not open the new container.
        XCTAssertThrowsError(try Vault.unlock(container: newContainer, dek: oldDEK, deviceKeyWasPresented: true)) {
            XCTAssertEqual($0 as? VaultError, .tampered)
        }
        // The legitimate path still works.
        let good = try Vault.unlock(container: newContainer, password: password, deviceKey: deviceKey)
        XCTAssertEqual(good.payload.entries.map(\.secret), makeTestPayload().entries.map(\.secret))
    }

    /// The direct-DEK entry point (biometric unlock) must enforce the device
    /// policy itself rather than trusting its caller.
    func testDirectDEKUnlockEnforcesDevicePolicy() throws {
        let (_, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let twoFactor = try DeviceKeyFactor.apply(
            to: unlocked, password: password, currentDeviceKey: nil,
            newPolicy: UnlockPolicy(requiresDevice: true, keyFileRelPath: VolumeDeviceKeyProvider.defaultKeyRelPath),
            newDeviceKey: deviceKey
        )
        let container = try Vault.seal(twoFactor)
        XCTAssertThrowsError(try Vault.unlock(container: container, dek: twoFactor.dek, deviceKeyWasPresented: false)) {
            XCTAssertEqual($0 as? VaultError, .deviceKeyRequired)
        }
        XCTAssertNoThrow(try Vault.unlock(container: container, dek: twoFactor.dek, deviceKeyWasPresented: true))
    }

    // MARK: - Path traversal

    /// keyFileRelPath comes from the unauthenticated header; `../` in it must
    /// not let a tampered vault read or write outside the volume.
    func testDeviceKeyPathTraversalIsRejected() {
        let volume = URL(fileURLWithPath: "/Volumes/USB")
        XCTAssertNil(VolumeDeviceKeyProvider.safeURL(volumeURL: volume, relPath: "../../etc/passwd"))
        XCTAssertNil(VolumeDeviceKeyProvider.safeURL(volumeURL: volume, relPath: "/etc/passwd"))
        XCTAssertNil(VolumeDeviceKeyProvider.safeURL(volumeURL: volume, relPath: ".safekey/../../../secret"))
        XCTAssertNil(VolumeDeviceKeyProvider.safeURL(volumeURL: volume, relPath: ""))
        XCTAssertEqual(
            VolumeDeviceKeyProvider.safeURL(volumeURL: volume, relPath: ".safekey/device.key")?.path,
            "/Volumes/USB/.safekey/device.key"
        )
    }
}
