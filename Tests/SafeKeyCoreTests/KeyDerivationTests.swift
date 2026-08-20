import XCTest
import CryptoKit
@testable import SafeKeyCore

final class KeyDerivationTests: XCTestCase {
    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// PBKDF2-HMAC-SHA256("password", "salt", 1 iteration) — published vector.
    /// Exercises the raw primitive: the vault-facing `deriveKey` rejects this
    /// salt length as structurally invalid, which is the point of that guard.
    func testKnownVector() throws {
        let key = try KeyDerivation.pbkdf2(password: "password", salt: Data("salt".utf8), iterations: 1)
        XCTAssertEqual(
            keyData(key).map { String(format: "%02x", $0) }.joined(),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        )
    }

    /// Hostile KDF parameters from a tampered header are corruption, not a
    /// credential failure — misclassifying them was a self-destruct trigger.
    func testHostileParamsReportCorruption() {
        let goodSalt = KeyDerivation.randomSalt()
        for params in [
            KDFParams(iterations: 0, salt: goodSalt),
            KDFParams(iterations: -1, salt: goodSalt),
            KDFParams(iterations: 5_000_000_000, salt: goodSalt),
            KDFParams(iterations: 1000, salt: Data([1, 2, 3])),
        ] {
            XCTAssertThrowsError(try KeyDerivation.deriveKey(password: "pw-pw-pw", params: params)) {
                XCTAssertEqual($0 as? VaultError, .corruptVault)
            }
        }
    }

    func testDeterministic() throws {
        let params = KDFParams(iterations: 1000, salt: KeyDerivation.randomSalt())
        let a = try KeyDerivation.deriveKey(password: "hunter2hunter2", params: params)
        let b = try KeyDerivation.deriveKey(password: "hunter2hunter2", params: params)
        XCTAssertEqual(keyData(a), keyData(b))
    }

    func testSaltAndIterationsChangeOutput() throws {
        let salt = KeyDerivation.randomSalt()
        let base = try KeyDerivation.deriveKey(password: "pw-pw-pw", params: KDFParams(iterations: 1000, salt: salt))
        let otherSalt = try KeyDerivation.deriveKey(password: "pw-pw-pw", params: KDFParams(iterations: 1000, salt: KeyDerivation.randomSalt()))
        let otherIter = try KeyDerivation.deriveKey(password: "pw-pw-pw", params: KDFParams(iterations: 1001, salt: salt))
        XCTAssertNotEqual(keyData(base), keyData(otherSalt))
        XCTAssertNotEqual(keyData(base), keyData(otherIter))
    }

    func testEmptyPasswordRejected() {
        let params = KDFParams(iterations: 1000, salt: KeyDerivation.randomSalt())
        XCTAssertThrowsError(try KeyDerivation.deriveKey(password: "", params: params)) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testCalibrationRespectsFloor() {
        XCTAssertGreaterThanOrEqual(KeyDerivation.calibratedIterations(), KeyDerivation.iterationFloor)
    }
}
