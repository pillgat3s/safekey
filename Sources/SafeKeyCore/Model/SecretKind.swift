import Foundation

/// What kind of secret an entry stores.
public enum SecretKind: Codable, Sendable, Equatable, Hashable {
    case seedPhrase(wordCount: Int)
    case privateKey

    public var displayName: String {
        switch self {
        case .seedPhrase(let count): "\(count)-Word Seed Phrase"
        case .privateKey: "Private Key"
        }
    }

    public var shortName: String {
        switch self {
        case .seedPhrase: "Seed Phrase"
        case .privateKey: "Private Key"
        }
    }

    public var isSeedPhrase: Bool {
        if case .seedPhrase = self { return true }
        return false
    }

    /// The lengths BIP-39 defines. Anything else is not necessarily wrong —
    /// the user may still be typing — but it is worth flagging quietly.
    public static let validWordCounts = [12, 15, 18, 21, 24]

    public static func isPlausibleWordCount(_ count: Int) -> Bool {
        validWordCounts.contains(count)
    }
}
