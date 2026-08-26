import Foundation
import Security

/// File I/O for the vault container. An actor so reads/writes serialize.
/// The directory is injectable for tests.
public actor VaultStore {
    public static let vaultFileName = "vault.safekey"

    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("SafeKey", isDirectory: true)
        }
    }

    /// On iOS, puts a file into the CompleteUnlessOpen protection class:
    /// unreadable while the device is locked, but a write already in flight
    /// when the lock happens finishes instead of failing. The vault is sealed
    /// by its own AES layer regardless — this adds the OS's at-rest layer on
    /// top, the way a credential store is expected to sit.
    ///
    /// Per file rather than via the default-data-protection entitlement,
    /// which would need a capability registered against the App ID.
    /// Best-effort: the simulator and macOS have no such classes.
    nonisolated static func protectAtRest(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
        #endif
    }

    nonisolated public var vaultURL: URL {
        directory.appendingPathComponent(Self.vaultFileName)
    }

    /// The directory holding the vault and its sidecar state (attempt mirror).
    nonisolated public var directoryURL: URL { directory }

    public func vaultExists() -> Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    public func read() throws -> Data {
        guard vaultExists() else { throw VaultError.vaultNotFound }
        return try Data(contentsOf: vaultURL)
    }

    /// Atomic: write to a temp file in the same directory, fsync, then
    /// rename over the old vault. Never leaves a partially written vault.
    ///
    /// The temp file is created with `O_EXCL | O_NOFOLLOW` at a unique name and
    /// mode 0600 from the start. A fixed, predictable temp path could otherwise
    /// be pre-created by another local user as a symlink (making us write
    /// ciphertext somewhere else) or left world-readable for the instant
    /// between `write` and `setAttributes`.
    public func write(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // createDirectory ignores attributes when the directory already exists,
        // so tighten it explicitly every time.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let tmp = directory.appendingPathComponent("\(Self.vaultFileName).\(UUID().uuidString).tmp")
        let descriptor = tmp.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw VaultError.cryptoFailure }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            throw error
        }

        do {
            _ = try fm.replaceItemAt(vaultURL, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
        Self.protectAtRest(vaultURL)
    }

    /// Whether the vault directory is held back from the device's iCloud/system
    /// backup.
    ///
    /// Included is the default and the useful setting: the backup contains the
    /// same sealed container that sits on disk, so iCloud only ever holds
    /// ciphertext the master password already protects — and it is what lets a
    /// vault survive a lost phone. Excluding it is for someone who would rather
    /// lose the vault than have a copy leave the device.
    public func isExcludedFromBackup() -> Bool {
        (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    public func setExcludedFromBackup(_ excluded: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    nonisolated public var syncStateURL: URL {
        directory.appendingPathComponent("sync.json")
    }

    /// Per-vault sync bookkeeping: the change token, a digest of what iCloud
    /// holds for each record, and deletions not sent yet. Not secret — ids,
    /// digests and dates, never a name or a key — but kept 0600 alongside the
    /// vault regardless.
    ///
    /// Written on the calling thread rather than through the actor.
    ///
    /// The file records deletions that have not reached iCloud yet, and a
    /// deletion that is still sitting in a queue when the app goes away is a
    /// deletion the other device never hears about. It is a few hundred bytes
    /// of ids, and the coordinator that writes it is its only writer.
    nonisolated public func saveSyncStateNow(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: syncStateURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: syncStateURL.path
        )
        Self.protectAtRest(syncStateURL)
    }

    public func clearSyncState() {
        try? FileManager.default.removeItem(at: syncStateURL)
    }

    nonisolated public var rescueURL: URL {
        directory.appendingPathComponent(Self.vaultFileName + ".pre-restore")
    }

    /// Keeps a copy of the vault as it was immediately before a restore, so an
    /// imported backup that turns out to be unopenable does not cost the user
    /// their working vault. Written atomically with the same 0600 perms.
    public func writeRescueCopy(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(Self.vaultFileName + ".rescue.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(rescueURL, withItemAt: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rescueURL.path)
        Self.protectAtRest(rescueURL)
    }

    public func rescueCopy() -> Data? {
        try? Data(contentsOf: rescueURL)
    }

    public func clearRescueCopy() {
        try? FileManager.default.removeItem(at: rescueURL)
    }

        /// Crypto-shredding step 2 (step 1 is deleting the Keychain items): a
    /// best-effort random overwrite of the container, then remove the whole
    /// directory. On APFS/SSD the overwrite may not touch the original
    /// blocks — the real deletion is the loss of every wrapped copy of the DEK.
    public func destroy() throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: vaultURL.path))?[.size] as? Int, size > 0 {
            let random = KeyDerivation.randomBytes(count: size)
            if let handle = try? FileHandle(forWritingTo: vaultURL) {
                try? handle.write(contentsOf: random)
                try? handle.synchronize()
                try? handle.close()
            }
        }
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
    }
}
