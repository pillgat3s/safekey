import Foundation

/// Byte-level codec for the `.safekey` container. Pure functions, no I/O.
///
/// Layout (little-endian):
///   [0..8)    magic "SFKVLT01"
///   [8..10)   container version, UInt16
///   [10..14)  header length H, UInt32
///   [14..14+H) header JSON, UTF-8
///   [14+H..)  AES-GCM combined box of payload (12-byte nonce ‖ ct ‖ 16-byte tag)
///
/// The AAD for the payload seal is exactly bytes [0..14+H) as they appear on
/// disk — the prefix returned by `prefix(headerJSON:)` and `Decoded.aad`.
public enum VaultFileFormat {
    public static let magic = Data("SFKVLT01".utf8)
    public static let containerVersion: UInt16 = 1
    static let prefixFixedLength = 14

    public struct Decoded: Sendable {
        public let header: VaultHeader
        /// The on-disk prefix bytes (magic ‖ version ‖ length ‖ header JSON).
        public let aad: Data
        public let sealedPayload: Data
    }

    public static func prefix(headerJSON: Data) -> Data {
        var out = magic
        let version = containerVersion.littleEndian
        out.append(UInt8(truncatingIfNeeded: version))
        out.append(UInt8(truncatingIfNeeded: version >> 8))
        let length = UInt32(headerJSON.count).littleEndian
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(headerJSON)
        return out
    }

    public static func encode(headerJSON: Data, sealedPayload: Data) -> Data {
        prefix(headerJSON: headerJSON) + sealedPayload
    }

    public static func decode(_ raw: Data) throws -> Decoded {
        let data = Data(raw) // normalize to zero-based indices
        guard data.count > prefixFixedLength else { throw VaultError.corruptVault }
        guard data.prefix(8) == magic else { throw VaultError.corruptVault }
        let version = UInt16(data[8]) | (UInt16(data[9]) << 8)
        guard version == containerVersion else { throw VaultError.unsupportedVersion(version) }
        let headerLength = UInt32(data[10]) | (UInt32(data[11]) << 8) | (UInt32(data[12]) << 16) | (UInt32(data[13]) << 24)
        let headerEnd = prefixFixedLength + Int(headerLength)
        guard headerEnd > prefixFixedLength, headerEnd < data.count else { throw VaultError.corruptVault }
        let headerJSON = data.subdata(in: prefixFixedLength..<headerEnd)
        guard let header = try? VaultJSON.decoder().decode(VaultHeader.self, from: headerJSON) else {
            throw VaultError.corruptVault
        }
        return Decoded(
            header: header,
            aad: data.subdata(in: 0..<headerEnd),
            sealedPayload: data.subdata(in: headerEnd..<data.count)
        )
    }
}
