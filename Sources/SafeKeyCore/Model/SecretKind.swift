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
}
