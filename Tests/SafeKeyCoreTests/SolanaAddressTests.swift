import XCTest
import CryptoKit
@testable import SafeKeyCore

final class SolanaAddressTests: XCTestCase {
    /// The canonical BIP-39 all-`abandon` vector with an empty passphrase.
    private let testMnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    // MARK: - Base58

    func testBase58RoundTrip() {
        for _ in 0..<200 {
            let data = KeyDerivation.randomBytes(count: Int.random(in: 1...64))
            let encoded = Base58.encode(data)
            XCTAssertEqual(Base58.decode(encoded), data)
        }
    }

    func testBase58KnownValues() {
        XCTAssertEqual(Base58.encode(Data([0])), "1")
        XCTAssertEqual(Base58.encode(Data([0, 0])), "11")
        XCTAssertEqual(Base58.encode(Data([1])), "2")
        XCTAssertEqual(Base58.encode(Data([57])), "z")
        XCTAssertEqual(Base58.encode(Data([58])), "21")
        // Leading zeros must survive a round trip — they are significant.
        let leading = Data([0, 0, 0, 5, 9])
        XCTAssertEqual(Base58.decode(Base58.encode(leading)), leading)
    }

    func testBase58RejectsInvalidCharacters() {
        // 0, O, I and l are excluded from the alphabet.
        XCTAssertNil(Base58.decode("0OIl"))
    }

    // MARK: - BIP-39

    /// Published BIP-39 test vector: the all-`abandon` mnemonic with an empty
    /// passphrase produces this 64-byte seed.
    func testBIP39KnownSeed() throws {
        let seed = try SolanaAddress.bip39Seed(mnemonic: testMnemonic)
        XCTAssertEqual(
            seed.map { String(format: "%02x", $0) }.joined(),
            "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1"
                + "9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
        )
    }

    func testPassphraseChangesSeed() throws {
        let plain = try SolanaAddress.bip39Seed(mnemonic: testMnemonic)
        let withPassphrase = try SolanaAddress.bip39Seed(mnemonic: testMnemonic, passphrase: "TREZOR")
        XCTAssertNotEqual(plain, withPassphrase)
    }

    // MARK: - Derivation

    func testDerivationIsDeterministic() throws {
        let first = try SolanaAddress.candidatesFromMnemonic(testMnemonic, accounts: 3)
        let second = try SolanaAddress.candidatesFromMnemonic(testMnemonic, accounts: 3)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testEachPathGivesADistinctAddress() throws {
        let candidates = try SolanaAddress.candidatesFromMnemonic(testMnemonic, accounts: 4)
        let addresses = Set(candidates.map(\.address))
        XCTAssertEqual(addresses.count, candidates.count, "different paths must not collide")
    }

    func testAddressesAreValidSolanaFormat() throws {
        for candidate in try SolanaAddress.candidatesFromMnemonic(testMnemonic, accounts: 2) {
            // A Solana address is a Base58-encoded 32-byte ed25519 public key.
            let decoded = Base58.decode(candidate.address)
            XCTAssertEqual(decoded?.count, 32, "\(candidate.path) produced a malformed address")
            XCTAssertTrue((32...44).contains(candidate.address.count))
        }
    }

    func testWrongWordCountRejected() {
        XCTAssertThrowsError(try SolanaAddress.candidatesFromMnemonic("abandon abandon about")) {
            XCTAssertEqual($0 as? SolanaAddress.DerivationError, .badWordCount(3))
        }
    }

    func testNonWordsRejected() {
        let notWords = Array(repeating: "1234", count: 12).joined(separator: " ")
        XCTAssertThrowsError(try SolanaAddress.candidatesFromMnemonic(notWords)) {
            XCTAssertEqual($0 as? SolanaAddress.DerivationError, .notAMnemonic)
        }
    }

    /// A single wrong word must change the derived address — that is what makes
    /// comparing against the wallet a real transcription check.
    func testOneWrongWordChangesEveryAddress() throws {
        let correct = try SolanaAddress.candidatesFromMnemonic(testMnemonic, accounts: 2)
        let typo = testMnemonic.replacingOccurrences(of: "about", with: "above")
        let wrong = try SolanaAddress.candidatesFromMnemonic(typo, accounts: 2)
        XCTAssertTrue(Set(correct.map(\.address)).isDisjoint(with: Set(wrong.map(\.address))))
    }

    // MARK: - Private keys

    func testPrivateKeyRoundTripsThroughItsOwnAddress() throws {
        // Build a keypair the way Solana exports one: 32-byte seed ‖ 32-byte
        // public key, Base58 encoded.
        let seed = KeyDerivation.randomBytes(count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let expected = Base58.encode(key.publicKey.rawRepresentation)

        var keypair = seed
        keypair.append(key.publicKey.rawRepresentation)

        let fromKeypair = try SolanaAddress.candidateFromPrivateKey(Base58.encode(keypair))
        XCTAssertEqual(fromKeypair.address, expected)
        XCTAssertTrue(fromKeypair.isExact)

        // A bare 32-byte secret must give the same answer.
        let fromSeed = try SolanaAddress.candidateFromPrivateKey(Base58.encode(seed))
        XCTAssertEqual(fromSeed.address, expected)

        // As must the solana-keygen JSON array form.
        let json = "[" + keypair.map(String.init).joined(separator: ",") + "]"
        XCTAssertEqual(try SolanaAddress.candidateFromPrivateKey(json).address, expected)

        // And hex.
        XCTAssertEqual(
            try SolanaAddress.candidateFromPrivateKey(seed.map { String(format: "%02x", $0) }.joined()).address,
            expected
        )
    }

    /// The public half of a stored keypair is ignored: the address is derived
    /// from the secret, so a corrupted file cannot display a plausible lie.
    func testCorruptedPublicHalfIsIgnored() throws {
        let seed = KeyDerivation.randomBytes(count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        var keypair = seed
        keypair.append(Data(repeating: 0xAB, count: 32)) // wrong public half

        XCTAssertEqual(
            try SolanaAddress.candidateFromPrivateKey(Base58.encode(keypair)).address,
            Base58.encode(key.publicKey.rawRepresentation)
        )
    }

    func testGarbagePrivateKeyRejected() {
        XCTAssertThrowsError(try SolanaAddress.candidateFromPrivateKey("not a key")) {
            XCTAssertEqual($0 as? SolanaAddress.DerivationError, .unrecognisedPrivateKeyFormat)
        }
    }

    func testNonSolanaEntryRejected() {
        let entry = WalletEntry(name: "BTC", chain: .bitcoin, kind: .privateKey, secret: "x")
        XCTAssertThrowsError(try SolanaAddress.candidates(for: entry)) {
            XCTAssertEqual($0 as? SolanaAddress.DerivationError, .unsupportedChain)
        }
    }
}
