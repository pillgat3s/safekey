import Foundation
import CryptoKit
import CommonCrypto

/// Derives Solana addresses from stored secrets — **entirely offline**.
///
/// Deriving an address is one-way arithmetic (private key → public key → encode)
/// and runs as pure local computation. Nothing is sent anywhere, and an address
/// cannot be inverted back to a key. SafeKey has no network code and this
/// feature deliberately adds none: asking a block explorer about an address
/// would leak the link between the user's IP and their wallet, which is a
/// privacy loss even though it is not a key loss.
///
/// The point of the feature is verification: if a derived address matches what
/// the user's wallet shows, the stored secret was transcribed correctly.
public enum SolanaAddress {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var id: String { path + address }
        /// BIP-32 path, or a description for non-path derivations.
        public let path: String
        /// Which wallets use this path, for the picker.
        public let label: String
        public let address: String
        /// True when the secret determines the address with no path ambiguity.
        public let isExact: Bool
    }

    public enum DerivationError: Error, Equatable, Sendable {
        case unsupportedChain
        case badWordCount(Int)
        case notAMnemonic
        case unrecognisedPrivateKeyFormat
        case failed
    }

    /// Word counts BIP-39 permits.
    static let validWordCounts = [12, 15, 18, 21, 24]

    // MARK: - Entry points

    /// `passphrase` is BIP-39's optional "25th word". A wallet configured with
    /// one derives entirely different addresses, which is the usual reason a
    /// derived address looks wrong when the arithmetic is correct.
    public static func candidates(
        for entry: WalletEntry,
        passphrase: String = "",
        accounts: Int = 5
    ) throws -> [Candidate] {
        guard entry.chain == .solana else { throw DerivationError.unsupportedChain }
        switch entry.kind {
        case .seedPhrase:
            return try candidatesFromMnemonic(entry.secret, passphrase: passphrase, accounts: accounts)
        case .privateKey:
            return [try candidateFromPrivateKey(entry.secret)]
        }
    }

    /// A private key fully determines its address — no derivation paths, no
    /// ambiguity, exactly one answer.
    public static func candidateFromPrivateKey(_ secret: String) throws -> Candidate {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = privateKeyBytes(trimmed) else {
            throw DerivationError.unrecognisedPrivateKeyFormat
        }
        let address: String
        switch raw.count {
        case 64:
            // Solana's usual export: 32-byte seed ‖ 32-byte public key. Derive
            // from the seed rather than trusting the stored public half, so a
            // corrupted file cannot show a plausible-but-wrong address.
            address = Base58.encode(try publicKey(fromSeed: raw.prefix(32)))
        case 32:
            address = Base58.encode(try publicKey(fromSeed: raw))
        default:
            throw DerivationError.unrecognisedPrivateKeyFormat
        }
        return Candidate(path: "—", label: "Derived from private key", address: address, isExact: true)
    }

    /// A mnemonic generates *infinitely many* addresses; which ones a wallet
    /// actually uses depends on its derivation path convention. These are the
    /// paths real Solana wallets use, in order of likelihood.
    public static func candidatesFromMnemonic(
        _ mnemonic: String,
        passphrase: String = "",
        accounts: Int = 5
    ) throws -> [Candidate] {
        let words = mnemonic.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard validWordCounts.contains(words.count) else {
            throw DerivationError.badWordCount(words.count)
        }
        guard words.allSatisfy({ $0.allSatisfy(\.isLetter) }) else {
            throw DerivationError.notAMnemonic
        }

        let seed = try bip39Seed(mnemonic: words.joined(separator: " "), passphrase: passphrase)
        var results: [Candidate] = []

        for account in 0..<max(1, accounts) {
            // Phantom, Solflare, Backpack: m/44'/501'/N'/0'
            let changePath = "m/44'/501'/\(account)'/0'"
            results.append(Candidate(
                path: changePath,
                label: account == 0 ? "Phantom, Solflare, Backpack (account 1)" : "Account \(account + 1)",
                address: Base58.encode(try publicKey(fromSeed: derive(seed: seed, path: [44, 501, account, 0]))),
                isExact: false
            ))
            // Some wallets stop at the account level: m/44'/501'/N'
            let accountPath = "m/44'/501'/\(account)'"
            results.append(Candidate(
                path: accountPath,
                label: account == 0 ? "Solana CLI, Ledger (account 1)" : "Account \(account + 1), short path",
                address: Base58.encode(try publicKey(fromSeed: derive(seed: seed, path: [44, 501, account]))),
                isExact: false
            ))
        }

        // Sollet and some older web wallets: m/501'/N'/0/0
        for account in 0..<max(1, accounts) {
            results.append(Candidate(
                path: "m/501'/\(account)'/0/0",
                label: account == 0 ? "Sollet, older web wallets" : "Sollet account \(account + 1)",
                address: Base58.encode(try publicKey(fromSeed: derive(seed: seed, path: [501, account, 0, 0]))),
                isExact: false
            ))
        }

        // Legacy solana-keygen wrote the raw seed's first 32 bytes.
        results.append(Candidate(
            path: "seed",
            label: "Legacy solana-keygen (no path)",
            address: Base58.encode(try publicKey(fromSeed: seed.prefix(32))),
            isExact: false
        ))
        return results
    }

    // MARK: - BIP-39

    /// BIP-39 seed: PBKDF2-HMAC-SHA512(NFKD(mnemonic), "mnemonic"+passphrase,
    /// 2048 iterations, 64 bytes). The wordlist is not needed for this — the
    /// mnemonic string itself is the password.
    static func bip39Seed(mnemonic: String, passphrase: String = "") throws -> Data {
        let normalisedMnemonic = Data(mnemonic.decomposedStringWithCompatibilityMapping.utf8)
        let salt = Data(("mnemonic" + passphrase.decomposedStringWithCompatibilityMapping).utf8)
        var output = [UInt8](repeating: 0, count: 64)
        defer { for index in output.indices { output[index] = 0 } }

        let status = normalisedMnemonic.withUnsafeBytes { password in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress?.assumingMemoryBound(to: Int8.self),
                    normalisedMnemonic.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    2048,
                    &output,
                    output.count
                )
            }
        }
        guard status == kCCSuccess else { throw DerivationError.failed }
        return Data(output)
    }

    // MARK: - SLIP-0010 (ed25519)

    /// ed25519 supports only hardened derivation, so every path element is
    /// hardened regardless of how it is written.
    static func derive(seed: Data, path: [Int]) throws -> Data {
        let mac = HMAC<SHA512>.authenticationCode(
            for: seed,
            using: SymmetricKey(data: Data("ed25519 seed".utf8))
        )
        var key = Data(mac.prefix(32))
        var chainCode = Data(mac.suffix(32))

        for element in path {
            guard element >= 0, element < 0x8000_0000 else { throw DerivationError.failed }
            let hardened = UInt32(element) | 0x8000_0000
            var payload = Data([0x00])
            payload.append(key)
            payload.append(UInt8(truncatingIfNeeded: hardened >> 24))
            payload.append(UInt8(truncatingIfNeeded: hardened >> 16))
            payload.append(UInt8(truncatingIfNeeded: hardened >> 8))
            payload.append(UInt8(truncatingIfNeeded: hardened))

            let child = HMAC<SHA512>.authenticationCode(
                for: payload,
                using: SymmetricKey(data: chainCode)
            )
            key = Data(child.prefix(32))
            chainCode = Data(child.suffix(32))
        }
        return key
    }

    /// The ed25519 public key of a 32-byte scalar seed — these bytes *are* the
    /// Solana address, before Base58 encoding.
    static func publicKey(fromSeed seed: any DataProtocol) throws -> Data {
        let bytes = Data(seed)
        guard bytes.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        else {
            throw DerivationError.failed
        }
        return key.publicKey.rawRepresentation
    }

    // MARK: - Private key formats

    /// Accepts the three ways Solana keys are written: Base58 (Phantom export),
    /// a JSON byte array (solana-keygen keypair files), and raw hex.
    static func privateKeyBytes(_ secret: String) -> Data? {
        if secret.hasPrefix("[") {
            let numbers = secret
                .trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
                .split(separator: ",")
                .compactMap { UInt8($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if numbers.count == 64 || numbers.count == 32 { return Data(numbers) }
            return nil
        }
        if let decoded = Base58.decode(secret), decoded.count == 64 || decoded.count == 32 {
            return decoded
        }
        let hex = secret.hasPrefix("0x") ? String(secret.dropFirst(2)) : secret
        if hex.count == 128 || hex.count == 64, hex.allSatisfy(\.isHexDigit) {
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
        return nil
    }
}
