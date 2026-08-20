import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum KDFAlgorithm: String, Codable, Sendable {
    case pbkdf2HmacSha256 = "pbkdf2-hmac-sha256"
}

public struct KDFParams: Codable, Sendable, Equatable {
    public var algorithm: KDFAlgorithm
    public var iterations: Int
    public var salt: Data

    public init(algorithm: KDFAlgorithm = .pbkdf2HmacSha256, iterations: Int, salt: Data) {
        self.algorithm = algorithm
        self.iterations = iterations
        self.salt = salt
    }
}

public enum KeyDerivation {
    /// OWASP-recommended minimum for PBKDF2-HMAC-SHA256.
    public static let iterationFloor = 600_000
    public static let iterationCeiling = 5_000_000

    public static func randomSalt(count: Int = 32) -> Data {
        randomBytes(count: count)
    }

    public static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// Lower bound applied when *reading* a container. Deliberately permissive:
    /// a tampered iteration count is not a confidentiality attack (a different
    /// count yields a different KEK, so the unwrap simply fails), and being
    /// strict here would reject vaults created by other builds. The bound
    /// exists only to reject structurally impossible values.
    public static let minimumAcceptedIterations = 1
    /// Every SafeKey vault uses a 32-byte salt; 16 leaves room for other
    /// implementations without accepting a degenerate one.
    public static let minimumSaltBytes = 16

    /// Derives the 256-bit password KEK. Runs ~250 ms by design — always call
    /// off the main actor.
    ///
    /// The KDF parameters arrive from the container's *unauthenticated* header,
    /// so they are hostile input. Two rules matter:
    ///
    /// 1. Structurally invalid parameters mean a corrupt or tampered file, not
    ///    a bad credential — they throw `.corruptVault`, never
    ///    `.wrongPassword`. Otherwise a one-byte file edit could make the
    ///    owner's *correct* password look wrong and, with self-destruct armed,
    ///    erase the vault.
    /// 2. `iterations` is bounds-checked before the `UInt32` conversion, which
    ///    traps on overflow — an unbounded value would be a permanent,
    ///    passwordless brick (and, below the ceiling, a denial of service).
    public static func deriveKey(password: String, params: KDFParams) throws -> SymmetricKey {
        guard case .pbkdf2HmacSha256 = params.algorithm else {
            throw VaultError.unsupportedKDF(params.algorithm.rawValue)
        }
        guard
            (minimumAcceptedIterations...iterationCeiling).contains(params.iterations),
            params.salt.count >= minimumSaltBytes
        else {
            throw VaultError.corruptVault
        }
        guard !password.isEmpty else {
            throw VaultError.wrongPassword
        }
        return try pbkdf2(password: password, salt: params.salt, iterations: params.iterations)
    }

    /// The raw primitive, without container-hygiene validation. Separated so
    /// published test vectors (which use short salts and low iteration counts)
    /// can exercise the KDF itself, while everything reachable from a vault
    /// file goes through the validating `deriveKey`.
    static func pbkdf2(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer {
            for i in derived.indices { derived[i] = 0 }
        }
        let status = passwordData.withUnsafeBytes { (pw: UnsafeRawBufferPointer) in
            salt.withUnsafeBytes { (saltBytes: UnsafeRawBufferPointer) in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    // Bounds-checked by the caller; `clamping` guarantees the
                    // conversion can never trap even if a new caller forgets.
                    UInt32(clamping: iterations),
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw VaultError.cryptoFailure }
        return SymmetricKey(data: Data(derived))
    }

    /// Picks an iteration count that costs roughly `targetSeconds` on this
    /// machine, never below the OWASP floor. Called once at vault creation;
    /// the chosen value is recorded in the header.
    public static func calibratedIterations(targetSeconds: Double = 0.25) -> Int {
        let probeIterations = 50_000
        let params = KDFParams(iterations: probeIterations, salt: randomSalt())
        let start = DispatchTime.now()
        _ = try? deriveKey(password: "calibration-probe", params: params)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        guard elapsed > 0.0001 else { return iterationFloor }
        let scaled = Int(Double(probeIterations) * targetSeconds / elapsed)
        return min(max(scaled, iterationFloor), iterationCeiling)
    }
}
