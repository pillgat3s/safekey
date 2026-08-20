import XCTest
@testable import SafeKeyCore

/// In-memory SecretStore so tests never touch the real Keychain.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var failReads = false

    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw KeychainService.KeychainError.unexpectedStatus(-34018) }
        return storage[account]
    }

    func write(_ data: Data, account: String, accessibility: KeychainAccessibility, trustingThisApp: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = data
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.isEmpty
    }
}

final class SelfDestructTests: XCTestCase {
    private var tempDir: URL!
    private var keychain: FakeSecretStore!
    private var anchors: VaultAnchorStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfDestructTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        keychain = FakeSecretStore()
        anchors = VaultAnchorStore(keychain: keychain, directory: tempDir)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func pinnedContainer(enabled: Bool = true, maxAttempts: Int = 3) throws -> Data {
        var (container, unlocked) = try Vault.create(password: "pw123456", payload: makeTestPayload(), iterations: testIterations)
        unlocked.header.selfDestruct = SelfDestructPolicy(enabled: enabled, maxAttempts: maxAttempts)
        container = try Vault.seal(unlocked)
        anchors.pin(container: container)
        return container
    }

    func testIncrementAndPinReset() throws {
        let container = try pinnedContainer()
        let digest = VaultAnchor.headerDigest(ofContainer: container)
        XCTAssertEqual(anchors.load()?.failedAttempts, 0)
        XCTAssertEqual(anchors.registerFailure(currentHeaderDigest: digest).attempts, 1)
        XCTAssertEqual(anchors.registerFailure(currentHeaderDigest: digest).attempts, 2)

        // A successful unlock re-pins and clears the counter.
        anchors.pin(container: container)
        XCTAssertEqual(anchors.load()?.failedAttempts, 0)
    }

    func testRemainingAttemptsReflectsPinnedPolicy() throws {
        let container = try pinnedContainer(maxAttempts: 5)
        let digest = VaultAnchor.headerDigest(ofContainer: container)
        XCTAssertEqual(anchors.remainingAttempts(), 5)
        _ = anchors.registerFailure(currentHeaderDigest: digest)
        _ = anchors.registerFailure(currentHeaderDigest: digest)
        XCTAssertEqual(anchors.remainingAttempts(), 3)
    }

    func testDisarmedPolicyNeverTriggers() throws {
        let container = try pinnedContainer(enabled: false, maxAttempts: 1)
        let digest = VaultAnchor.headerDigest(ofContainer: container)
        for _ in 0..<10 {
            XCTAssertFalse(anchors.registerFailure(currentHeaderDigest: digest).shouldDestroy)
        }
        XCTAssertNil(anchors.remainingAttempts())
    }

    func testShouldTriggerPurePolicy() {
        let armed = SelfDestructPolicy(enabled: true, maxAttempts: 3)
        let disarmed = SelfDestructPolicy(enabled: false, maxAttempts: 3)
        XCTAssertFalse(SelfDestruct.shouldTrigger(policy: armed, failedCount: 2))
        XCTAssertTrue(SelfDestruct.shouldTrigger(policy: armed, failedCount: 3))
        XCTAssertFalse(SelfDestruct.shouldTrigger(policy: disarmed, failedCount: 100))
    }

    func testExecuteWipesEverythingAndReportsSuccess() async throws {
        let store = VaultStore(directory: tempDir)
        let (container, _) = try Vault.create(password: "pw123456", payload: makeTestPayload(), iterations: testIterations)
        try await store.write(container)
        try keychain.write(Data([1, 2, 3]), account: "dek.bio.something", accessibility: .whenUnlockedThisDeviceOnly)

        let ok = await SelfDestruct.execute(store: store, keychain: keychain)

        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.vaultURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        XCTAssertTrue(keychain.isEmpty, "every wrapped copy of the DEK must be gone")
    }

    func testAnchorClearRemovesBothStores() throws {
        _ = try pinnedContainer()
        XCTAssertNotNil(anchors.load())
        anchors.clear()
        XCTAssertNil(anchors.load())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(VaultAnchorStore.mirrorFileName).path)
        )
    }

    /// The real `KeychainService` must not report failure when the
    /// data-protection keychain is unreachable. An ad-hoc signed build has no
    /// application-identifier, so that domain returns errSecMissingEntitlement
    /// for everything — and treating it as an error made every delete throw,
    /// which silently broke enabling Touch ID.
    func testDeleteToleratesUnreachableDataProtectionKeychain() throws {
        let service = "com.andri.safekey.test.\(UUID().uuidString)"
        let keychain = KeychainService(service: service)
        XCTAssertNoThrow(try keychain.delete(account: "absent"))

        try keychain.write(Data([9, 9, 9]), account: "present", accessibility: .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(try keychain.read(account: "present"), Data([9, 9, 9]))
        XCTAssertNoThrow(try keychain.delete(account: "present"))
        XCTAssertNil(try keychain.read(account: "present"))
        XCTAssertNoThrow(try keychain.deleteAll())
    }

    func testHeaderModificationIsDetectedWithoutAPassword() throws {
        let container = try pinnedContainer()
        XCTAssertFalse(anchors.containerWasModified(container: container))

        let decoded = try VaultFileFormat.decode(container)
        var header = decoded.header
        header.selfDestruct = SelfDestructPolicy(enabled: true, maxAttempts: 1)
        let json = try VaultJSON.encoder().encode(header)
        let forged = VaultFileFormat.encode(headerJSON: json, sealedPayload: decoded.sealedPayload)

        XCTAssertTrue(anchors.containerWasModified(container: forged))
    }
}
