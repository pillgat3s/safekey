import Foundation

/// Bitcoin-alphabet Base58 (no checksum). Solana addresses and private keys
/// are both expressed in this encoding.
public enum Base58 {
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let zero = alphabet[0]

    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        // Repeated base-256 → base-58 division, little-endian accumulator.
        var digits: [Int] = []
        for byte in data {
            var carry = Int(byte)
            for index in digits.indices {
                carry += digits[index] << 8
                digits[index] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        // Leading zero bytes are significant in Base58 and encode as '1'.
        let leadingZeros = data.prefix { $0 == 0 }.count
        return String(repeating: String(zero), count: leadingZeros)
            + String(digits.reversed().map { alphabet[$0] })
    }

    public static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }
        var bytes: [Int] = []
        for character in string {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            var carry = value
            for index in bytes.indices {
                carry += bytes[index] * 58
                bytes[index] = carry & 0xFF
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(carry & 0xFF)
                carry >>= 8
            }
        }
        let leadingZeros = string.prefix { $0 == zero }.count
        var result = Data(repeating: 0, count: leadingZeros)
        result.append(contentsOf: bytes.reversed().map { UInt8($0) })
        return result
    }
}
