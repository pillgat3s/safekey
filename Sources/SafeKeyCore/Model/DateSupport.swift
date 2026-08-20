import Foundation

extension Date {
    /// The vault serializes dates as ISO 8601 with second precision. Anything
    /// stored in vault models uses whole-second dates so in-memory values
    /// always equal their persisted round-trip.
    public static func vaultNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}
