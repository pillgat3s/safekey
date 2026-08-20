import Foundation

/// A blockchain a wallet belongs to.
///
/// Encoded as a **single JSON string** (`"bitcoin"`, `"evm"`,
/// `"custom:Monero"`) rather than Swift's default enum-with-payload object.
/// That keeps the vault format readable by a non-Swift client — see FORMAT.md —
/// and lets new chains be added without changing the schema. Vaults written by
/// earlier builds used the old object form and still decode; see `init(from:)`.
public enum Chain: Sendable, Equatable, Hashable, Identifiable {
    case known(KnownChain)
    /// A chain not in the catalog, named by the user.
    case custom(String)

    public var id: String {
        switch self {
        case .known(let chain): chain.rawValue
        case .custom(let name): "custom:" + name
        }
    }

    public static let bitcoin = Chain.known(.bitcoin)
    /// Ethereum and every EVM-compatible network — one seed phrase covers them
    /// all, which is why this is "EVM" rather than "Ethereum".
    public static let evm = Chain.known(.evm)
    public static let solana = Chain.known(.solana)

    public var displayName: String {
        switch self {
        case .known(let chain): chain.displayName
        case .custom(let name):
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : name
        }
    }

    /// Short ticker-style label used by the compact lettermark logo.
    public var shortCode: String {
        switch self {
        case .known(let chain):
            return chain.shortCode
        case .custom(let name):
            let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            // "Hyper Liquid" → "HL"; "Monero" → "MON".
            if words.count >= 2 {
                return words.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
            }
            guard let first = words.first else { return "?" }
            return String(first.prefix(3)).uppercased()
        }
    }

    /// Brand colour as `#RRGGBB`. Resolved to a `Color` by the app layer so
    /// this framework stays free of UI imports.
    public var colorHex: String {
        switch self {
        case .known(let chain):
            return chain.colorHex
        case .custom(let name):
            let palette = KnownChain.customPalette
            return palette[Int(Self.stableHash(name) % UInt64(palette.count))]
        }
    }

    /// FNV-1a. `String.hashValue` is seeded per process, so using it here would
    /// give a custom chain a different colour on every launch.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// Everything offered in the picker, in catalogue order.
    public static var catalog: [Chain] {
        KnownChain.allCases.map(Chain.known)
    }
}

/// Chains with a built-in logo and brand colour.
///
/// Only networks with their **own key format** are listed. Every EVM-compatible
/// chain — L2s like Base, Arbitrum, Optimism and zkSync, and EVM L1s like BNB
/// Smart Chain, Polygon and Avalanche C-Chain — shares Ethereum's key
/// derivation, so one `evm` entry covers them all. Listing them separately
/// would imply a distinction that does not exist for a key vault.
public enum KnownChain: String, Sendable, CaseIterable, Codable {
    case bitcoin
    case evm
    case solana
    case ton
    case tron
    case cardano
    case polkadot
    case xrp
    case litecoin
    case monero
    case cosmos
    case sui
    case aptos
    case near
    case stellar
    case dogecoin
    case bitcoinCash = "bitcoin-cash"
    case zcash
    case tezos
    case algorand
    case hedera
    case filecoin

    public var displayName: String {
        switch self {
        case .bitcoin: "Bitcoin"
        case .evm: "EVM"
        case .solana: "Solana"
        case .ton: "TON"
        case .tron: "Tron"
        case .cardano: "Cardano"
        case .polkadot: "Polkadot"
        case .xrp: "XRP Ledger"
        case .litecoin: "Litecoin"
        case .monero: "Monero"
        case .cosmos: "Cosmos"
        case .sui: "Sui"
        case .aptos: "Aptos"
        case .near: "NEAR"
        case .stellar: "Stellar"
        case .dogecoin: "Dogecoin"
        case .bitcoinCash: "Bitcoin Cash"
        case .zcash: "Zcash"
        case .tezos: "Tezos"
        case .algorand: "Algorand"
        case .hedera: "Hedera"
        case .filecoin: "Filecoin"
        }
    }

    /// Extra context shown under the name in the picker.
    public var subtitle: String {
        switch self {
        case .evm: "Ethereum · Base · Arbitrum · Polygon · BNB · every L2"
        case .bitcoin: "BTC · legacy, SegWit, Taproot"
        case .cosmos: "ATOM · Osmosis, Celestia, Injective…"
        default: shortCode
        }
    }

    public var shortCode: String {
        switch self {
        case .bitcoin: "BTC"
        case .evm: "EVM"
        case .solana: "SOL"
        case .ton: "TON"
        case .tron: "TRX"
        case .cardano: "ADA"
        case .polkadot: "DOT"
        case .xrp: "XRP"
        case .litecoin: "LTC"
        case .monero: "XMR"
        case .cosmos: "ATOM"
        case .sui: "SUI"
        case .aptos: "APT"
        case .near: "NEAR"
        case .stellar: "XLM"
        case .dogecoin: "DOGE"
        case .bitcoinCash: "BCH"
        case .zcash: "ZEC"
        case .tezos: "XTZ"
        case .algorand: "ALGO"
        case .hedera: "HBAR"
        case .filecoin: "FIL"
        }
    }

    public var colorHex: String {
        switch self {
        case .bitcoin: "#F7931A"
        case .evm: "#627EEA"
        case .solana: "#14F195"
        case .ton: "#0098EA"
        case .tron: "#EF0027"
        case .cardano: "#0133AD"
        case .polkadot: "#E6007A"
        case .xrp: "#23292F"
        case .litecoin: "#345D9D"
        case .monero: "#FF6600"
        case .cosmos: "#2E3148"
        case .sui: "#4DA2FF"
        case .aptos: "#1E1E1E"
        case .near: "#00EC97"
        case .stellar: "#7D00FF"
        case .dogecoin: "#C2A633"
        case .bitcoinCash: "#0AC18E"
        case .zcash: "#F4B728"
        case .tezos: "#2C7DF7"
        case .algorand: "#000000"
        case .hedera: "#000000"
        case .filecoin: "#0090FF"
        }
    }

    static let customPalette = [
        "#8E8E93", "#5E5CE6", "#FF9F0A", "#30D158", "#FF375F", "#64D2FF", "#BF5AF2",
    ]
}

// MARK: - Codable (portable string form, backwards compatible)

extension Chain: Codable {
    private static let customPrefix = "custom:"

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .known(let chain):
            try container.encode(chain.rawValue)
        case .custom(let name):
            try container.encode(Self.customPrefix + name)
        }
    }

    public init(from decoder: any Decoder) throws {
        // Current form: a plain string.
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            if raw.hasPrefix(Self.customPrefix) {
                self = .custom(String(raw.dropFirst(Self.customPrefix.count)))
            } else if let known = KnownChain(rawValue: raw) {
                self = .known(known)
            } else if raw == "ethereum" {
                // Renamed to `evm`; vaults written before the rename still say
                // "ethereum".
                self = .known(.evm)
            } else {
                // Unknown identifier from a newer build: keep the value rather
                // than failing the whole payload decode, which would make the
                // vault look corrupt.
                self = .custom(raw)
            }
            return
        }

        // Legacy form: Swift's synthesised enum encoding, e.g. {"ethereum":{}}
        // or {"other":{"_0":"Monero"}}.
        let legacy = try decoder.container(keyedBy: LegacyKey.self)
        guard let key = legacy.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised chain encoding")
            )
        }
        switch key.stringValue {
        case "bitcoin": self = .known(.bitcoin)
        case "ethereum": self = .known(.evm)
        case "solana": self = .known(.solana)
        case "other":
            let nested = try legacy.nestedContainer(keyedBy: LegacyKey.self, forKey: key)
            let name = (try? nested.decode(String.self, forKey: LegacyKey(stringValue: "_0")!)) ?? "Custom"
            self = .custom(name)
        default:
            self = .custom(key.stringValue)
        }
    }

    private struct LegacyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
