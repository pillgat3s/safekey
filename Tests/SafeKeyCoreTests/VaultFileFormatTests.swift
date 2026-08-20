import XCTest
@testable import SafeKeyCore

final class VaultFileFormatTests: XCTestCase {
    private func makeContainer() throws -> Data {
        try Vault.create(password: "pw123456", payload: makeTestPayload(), iterations: testIterations).container
    }

    func testDecodeRoundTrip() throws {
        let container = try makeContainer()
        let decoded = try VaultFileFormat.decode(container)
        XCTAssertEqual(decoded.aad + decoded.sealedPayload, container)
        XCTAssertEqual(decoded.header.formatVersion, 1)
        XCTAssertTrue(decoded.aad.starts(with: VaultFileFormat.magic))
    }

    func testBadMagicRejected() throws {
        var container = try makeContainer()
        container[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try VaultFileFormat.decode(container)) {
            XCTAssertEqual($0 as? VaultError, .corruptVault)
        }
    }

    func testUnsupportedVersionRejected() throws {
        var container = try makeContainer()
        container[8] = 99
        XCTAssertThrowsError(try VaultFileFormat.decode(container)) {
            XCTAssertEqual($0 as? VaultError, .unsupportedVersion(99))
        }
    }

    func testTruncatedRejected() throws {
        let container = try makeContainer()
        XCTAssertThrowsError(try VaultFileFormat.decode(container.prefix(10))) {
            XCTAssertEqual($0 as? VaultError, .corruptVault)
        }
        XCTAssertThrowsError(try VaultFileFormat.decode(container.prefix(40))) {
            XCTAssertEqual($0 as? VaultError, .corruptVault)
        }
    }

    func testCiphertextBitFlipDetected() throws {
        var container = try makeContainer()
        container[container.count - 20] ^= 0x01
        XCTAssertThrowsError(try Vault.unlock(container: container, password: "pw123456")) {
            XCTAssertEqual($0 as? VaultError, .tampered)
        }
    }

    /// Header modification that leaves the KEK derivation unchanged (so the
    /// DEK still unwraps) must still be caught by the payload AAD. This is
    /// what stops an attacker silently flipping the self-destruct policy.
    func testHeaderTamperDetectedViaAAD() throws {
        let container = try makeContainer()
        let decoded = try VaultFileFormat.decode(container)

        var tamperedHeader = decoded.header
        tamperedHeader.selfDestruct = SelfDestructPolicy(enabled: true, maxAttempts: 1)
        let tamperedJSON = try VaultJSON.encoder().encode(tamperedHeader)
        let forged = VaultFileFormat.encode(headerJSON: tamperedJSON, sealedPayload: decoded.sealedPayload)

        XCTAssertThrowsError(try Vault.unlock(container: forged, password: "pw123456")) {
            XCTAssertEqual($0 as? VaultError, .tampered)
        }
    }
}
