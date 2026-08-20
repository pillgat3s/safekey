import XCTest
import CryptoKit
@testable import SafeKeyCore

/// Fast KDF params for tests — correctness is iteration-count independent.
let testIterations = 1000

func makeTestPayload() -> VaultPayload {
    // Whole-second dates: the vault serializes dates as ISO 8601 (second
    // precision), so equality round-trips only for whole seconds.
    let date = Date(timeIntervalSince1970: 1_753_800_000)
    return VaultPayload(entries: [
        WalletEntry(
            name: "Main ETH",
            chain: .evm,
            kind: .seedPhrase(wordCount: 12),
            secret: "abandon ability able about above absent absorb abstract absurd abuse access accident",
            publicAddress: "0x1111111111111111111111111111111111111111",
            tags: ["hot", "main"],
            createdAt: date,
            modifiedAt: date
        ),
        WalletEntry(
            name: "BTC cold-ish",
            chain: .bitcoin,
            kind: .privateKey,
            secret: "L1aW4aubDFB7yfras2S1mN3bqg9nwySY8nkoLmJebSLD5BWv3ENZ",
            createdAt: date,
            modifiedAt: date
        ),
    ])
}

final class VaultCryptoTests: XCTestCase {
    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    func testCreateUnlockRoundTrip() throws {
        let payload = makeTestPayload()
        let (container, created) = try Vault.create(password: "correct horse battery", payload: payload, iterations: testIterations)
        let unlocked = try Vault.unlock(container: container, password: "correct horse battery")
        XCTAssertEqual(unlocked.payload, payload)
        XCTAssertEqual(keyData(unlocked.dek), keyData(created.dek))
        XCTAssertEqual(unlocked.header, created.header)
    }

    func testWrongPasswordFails() throws {
        let (container, _) = try Vault.create(password: "right password", payload: makeTestPayload(), iterations: testIterations)
        XCTAssertThrowsError(try Vault.unlock(container: container, password: "wrong password")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testDirectDEKUnlock() throws {
        let payload = makeTestPayload()
        let (container, created) = try Vault.create(password: "pw123456", payload: payload, iterations: testIterations)
        let unlocked = try Vault.unlock(container: container, dek: created.dek)
        XCTAssertEqual(unlocked.payload, payload)
    }

    func testMutateAndResealRoundTrip() throws {
        let (container, created) = try Vault.create(password: "pw123456", payload: makeTestPayload(), iterations: testIterations)
        var unlocked = try Vault.unlock(container: container, password: "pw123456")
        unlocked.payload.entries.removeLast()
        let resealed = try Vault.seal(unlocked)
        XCTAssertNotEqual(resealed, container, "fresh nonce must change ciphertext")
        let reopened = try Vault.unlock(container: resealed, dek: created.dek)
        XCTAssertEqual(reopened.payload.entries.count, 1)
    }

    func testChangePassword() throws {
        let payload = makeTestPayload()
        let (container, created) = try Vault.create(password: "old password", payload: payload, iterations: testIterations)
        let changed = try Vault.changePassword(container: container, oldPassword: "old password", newPassword: "new password")

        XCTAssertThrowsError(try Vault.unlock(container: changed, password: "old password")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
        let unlocked = try Vault.unlock(container: changed, password: "new password")
        XCTAssertEqual(unlocked.payload, payload)
        // DEK must survive a password change (keeps the biometric Keychain copy valid).
        XCTAssertEqual(keyData(unlocked.dek), keyData(created.dek))
    }

    func testChangePasswordRequiresOldPassword() throws {
        let (container, _) = try Vault.create(password: "old password", payload: makeTestPayload(), iterations: testIterations)
        XCTAssertThrowsError(try Vault.changePassword(container: container, oldPassword: "not it", newPassword: "new")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testCombinedKEKProperties() {
        let passwordKEK = SymmetricKey(size: .bits256)
        let deviceKey = KeyDerivation.randomBytes(count: 32)
        let salt = KeyDerivation.randomSalt()
        let a = VaultCrypto.combinedKEK(passwordKEK: passwordKEK, deviceKey: deviceKey, salt: salt)
        let b = VaultCrypto.combinedKEK(passwordKEK: passwordKEK, deviceKey: deviceKey, salt: salt)
        let otherDevice = VaultCrypto.combinedKEK(passwordKEK: passwordKEK, deviceKey: KeyDerivation.randomBytes(count: 32), salt: salt)
        XCTAssertEqual(keyData(a), keyData(b))
        XCTAssertNotEqual(keyData(a), keyData(otherDevice))
    }
}
