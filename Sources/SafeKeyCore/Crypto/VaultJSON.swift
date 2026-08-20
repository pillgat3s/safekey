import Foundation

/// Shared JSON coding configuration for everything that ends up inside the
/// vault container. Deliberately portable: ISO 8601 dates (UTC, second
/// precision), base64 Data, sorted keys — a non-Apple client can reproduce
/// this exactly. See FORMAT.md.
public enum VaultJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
