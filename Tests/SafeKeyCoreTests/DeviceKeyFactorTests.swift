import XCTest
import CryptoKit
@testable import SafeKeyCore

/// In-memory provider: volumes are dictionaries, no USB hardware involved.
final class FakeDeviceKeyProvider: DeviceKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    var volumes: [RemovableVolume] = []
    private var files: [String: Data] = [:]

    func candidateVolumes() -> [RemovableVolume] {
        lock.lock(); defer { lock.unlock() }
        return volumes
    }

    func readKey(volumeURL: URL, relPath: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[volumeURL.appendingPathComponent(relPath).path]
    }

    func writeKey(_ key: Data, volumeURL: URL, relPath: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[volumeURL.appendingPathComponent(relPath).path] = key
    }

    func removeKey(volumeURL: URL, relPath: String) {
        lock.lock(); defer { lock.unlock() }
        files[volumeURL.appendingPathComponent(relPath).path] = nil
    }
}

final class DeviceKeyFactorTests: XCTestCase {
    private let password = "correct horse battery"
    private let relPath = VolumeDeviceKeyProvider.defaultKeyRelPath

    private func makeVault() throws -> (Data, Vault.Unlocked) {
        let (container, unlocked) = try Vault.create(password: password, payload: makeTestPayload(), iterations: testIterations)
        return (container, unlocked)
    }

    private func enabledVault() throws -> (container: Data, deviceKey: Data) {
        let (_, unlocked) = try makeVault()
        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let policy = UnlockPolicy(requiresDevice: true, volumeUUID: "TEST-UUID", volumeName: "KEYSTICK", keyFileRelPath: relPath)
        let updated = try DeviceKeyFactor.apply(
            to: unlocked, password: password,
            currentDeviceKey: nil, newPolicy: policy, newDeviceKey: deviceKey
        )
        return (try Vault.seal(updated), deviceKey)
    }

    func testEnableThenUnlockRequiresDeviceKey() throws {
        let (container, deviceKey) = try enabledVault()

        // Password alone: refused before any KDF work with a distinct error.
        XCTAssertThrowsError(try Vault.unlock(container: container, password: password)) {
            XCTAssertEqual($0 as? VaultError, .deviceKeyRequired)
        }
        // Wrong stick: fails as wrongPassword (indistinguishable on purpose).
        XCTAssertThrowsError(try Vault.unlock(container: container, password: password, deviceKey: DeviceKeyFactor.generateDeviceKey())) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
        // Correct password + stick.
        let unlocked = try Vault.unlock(container: container, password: password, deviceKey: deviceKey)
        XCTAssertEqual(unlocked.payload.entries.map(\.name), makeTestPayload().entries.map(\.name))
        XCTAssertEqual(unlocked.payload.entries.map(\.secret), makeTestPayload().entries.map(\.secret))
        XCTAssertTrue(unlocked.header.unlockPolicy.requiresDevice)
    }

    func testDisableRestoresPasswordOnlyUnlock() throws {
        let (container, deviceKey) = try enabledVault()
        let unlocked = try Vault.unlock(container: container, password: password, deviceKey: deviceKey)

        let disabled = try DeviceKeyFactor.apply(
            to: unlocked, password: password,
            currentDeviceKey: deviceKey, newPolicy: UnlockPolicy(), newDeviceKey: nil
        )
        let resealed = try Vault.seal(disabled)

        let reopened = try Vault.unlock(container: resealed, password: password)
        XCTAssertFalse(reopened.header.unlockPolicy.requiresDevice)
    }

    func testDisableRequiresCurrentStick() throws {
        let (container, deviceKey) = try enabledVault()
        let unlocked = try Vault.unlock(container: container, password: password, deviceKey: deviceKey)
        XCTAssertThrowsError(
            try DeviceKeyFactor.apply(
                to: unlocked, password: password,
                currentDeviceKey: nil, newPolicy: UnlockPolicy(), newDeviceKey: nil
            )
        ) {
            XCTAssertEqual($0 as? VaultError, .deviceKeyRequired)
        }
    }

    func testEnableRejectsWrongPassword() throws {
        let (_, unlocked) = try makeVault()
        XCTAssertThrowsError(
            try DeviceKeyFactor.apply(
                to: unlocked, password: "not the password",
                currentDeviceKey: nil,
                newPolicy: UnlockPolicy(requiresDevice: true, keyFileRelPath: relPath),
                newDeviceKey: DeviceKeyFactor.generateDeviceKey()
            )
        ) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testBiometricBlobComposition() throws {
        // With the device factor on, the Keychain biometric blob is
        // AES.GCM(deviceKey, DEK): biometrics alone must not yield the DEK.
        let dek = VaultCrypto.generateDEK()
        let deviceKey = DeviceKeyFactor.generateDeviceKey()
        let blob = try VaultCrypto.wrapDEK(dek, under: SymmetricKey(data: deviceKey))

        XCTAssertThrowsError(try VaultCrypto.unwrapDEK(blob, under: SymmetricKey(data: DeviceKeyFactor.generateDeviceKey())))
        let unwrapped = try VaultCrypto.unwrapDEK(blob, under: SymmetricKey(data: deviceKey))
        XCTAssertEqual(
            unwrapped.withUnsafeBytes { Data($0) },
            dek.withUnsafeBytes { Data($0) }
        )
    }

    /// A second volume carrying a key file must not shadow the real stick:
    /// every candidate is returned so the caller can try them all before
    /// charging a failed attempt.
    func testLocateReturnsAllCandidatesWithPreferredFirst() {
        let provider = FakeDeviceKeyProvider()
        let realKey = DeviceKeyFactor.generateDeviceKey()
        let decoyKey = DeviceKeyFactor.generateDeviceKey()
        let decoy = RemovableVolume(url: URL(fileURLWithPath: "/Volumes/DECOY"), name: "DECOY", uuid: "UUID-DECOY", isRemovable: true)
        let real = RemovableVolume(url: URL(fileURLWithPath: "/Volumes/REAL"), name: "REAL", uuid: "UUID-REAL", isRemovable: true)
        // Decoy is enumerated first.
        provider.volumes = [decoy, real]
        try? provider.writeKey(decoyKey, volumeURL: decoy.url, relPath: relPath)
        try? provider.writeKey(realKey, volumeURL: real.url, relPath: relPath)

        let policy = UnlockPolicy(requiresDevice: true, volumeUUID: "UUID-REAL", volumeName: "REAL", keyFileRelPath: relPath)
        let keys = provider.locateDeviceKeys(policy: policy)
        XCTAssertEqual(keys.count, 2, "both candidates must be offered")
        XCTAssertEqual(keys.first, realKey, "the UUID match must be tried first")
        XCTAssertTrue(keys.contains(decoyKey))
    }

    func testLocateDeviceKeyPrefersUUIDThenFallsBack(){
        let provider = FakeDeviceKeyProvider()
        let key = DeviceKeyFactor.generateDeviceKey()
        let volumeA = RemovableVolume(url: URL(fileURLWithPath: "/Volumes/A"), name: "A", uuid: "UUID-A", isRemovable: true)
        let volumeB = RemovableVolume(url: URL(fileURLWithPath: "/Volumes/B"), name: "B", uuid: "UUID-B", isRemovable: true)
        provider.volumes = [volumeA, volumeB]
        try? provider.writeKey(key, volumeURL: volumeB.url, relPath: relPath)

        // Policy points at UUID-A (renamed/reformatted stick) — key actually
        // lives on B: fallback scan must find it.
        let policy = UnlockPolicy(requiresDevice: true, volumeUUID: "UUID-A", volumeName: "A", keyFileRelPath: relPath)
        XCTAssertEqual(provider.locateDeviceKey(policy: policy), key)

        // Not mounted at all → nil.
        provider.volumes = []
        XCTAssertNil(provider.locateDeviceKey(policy: policy))
    }
}
