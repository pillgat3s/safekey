import Foundation
import SafeKeyCore

/// Keeps an encrypted copy of the vault in iCloud Drive.
///
/// What is written is the *same* AES-GCM container that lives on disk — the
/// bytes are already sealed with the master password (and the USB key, when
/// that factor is on), so iCloud only ever holds ciphertext. Apple, and anyone
/// who obtains the file, sees an opaque blob; there is no new key material and
/// no new cryptography here.
///
/// This writes to the user's iCloud Drive folder rather than an app ubiquity
/// container on purpose: a ubiquity container needs an iCloud entitlement and a
/// provisioning profile, whereas the unsandboxed Mac app can use iCloud Drive
/// today. The file is also then visible to the user, which is what you want
/// from a backup you may need to find from another machine.
@MainActor
final class CloudBackupService {
    static let shared = CloudBackupService()

    private init() {}

    static let folderName = "SafeKey"
    static let fileName = "SafeKey Vault Backup.safekey"

    private var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// iCloud Drive is only usable if the user actually has it switched on.
    var isAvailable: Bool { iCloudDrive != nil }

    var backupURL: URL? {
        iCloudDrive?
            .appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    var lastBackupDate: Date? {
        guard let backupURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: backupURL.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    enum CloudBackupError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "iCloud Drive isn't available. Turn it on in System Settings → Apple Account → iCloud."
        }
    }

    /// Writes the container atomically. Safe to call on every vault change.
    func write(_ container: Data) throws {
        guard let backupURL else { throw CloudBackupError.unavailable }
        let folder = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try container.write(to: backupURL, options: [.atomic])
        // Owner-only, in case the folder is ever synced somewhere less private.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
    }

    func removeBackup() {
        guard let backupURL else { return }
        try? FileManager.default.removeItem(at: backupURL)
    }
}
