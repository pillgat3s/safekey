import XCTest
@testable import SafeKeyCore

final class VaultStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeyTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testWriteReadRoundTrip() async throws {
        let store = VaultStore(directory: tempDir)
        let data = Data("hello vault".utf8)
        try await store.write(data)
        let read = try await store.read()
        XCTAssertEqual(read, data)
    }

    func testOverwriteIsAtomicReplacement() async throws {
        let store = VaultStore(directory: tempDir)
        try await store.write(Data("first".utf8))
        try await store.write(Data("second".utf8))
        let read = try await store.read()
        XCTAssertEqual(read, Data("second".utf8))
    }

    func testPermissionsAre0600() async throws {
        let store = VaultStore(directory: tempDir)
        try await store.write(Data("secret".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.vaultURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testReadMissingThrowsNotFound() async {
        let store = VaultStore(directory: tempDir)
        do {
            _ = try await store.read()
            XCTFail("expected vaultNotFound")
        } catch {
            XCTAssertEqual(error as? VaultError, .vaultNotFound)
        }
    }

    func testDestroyRemovesEverything() async throws {
        let store = VaultStore(directory: tempDir)
        try await store.write(Data("doomed".utf8))
        try await store.destroy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testRescueCopyRoundTripAndClear() async throws {
        let store = VaultStore(directory: tempDir)
        try await store.write(Data("current vault".utf8))
        let current = try await store.read()
        try await store.writeRescueCopy(current)

        let rescued = await store.rescueCopy()
        XCTAssertEqual(rescued, current)

        await store.clearRescueCopy()
        let afterClear = await store.rescueCopy()
        XCTAssertNil(afterClear)
    }
}
