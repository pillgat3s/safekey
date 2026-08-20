import Foundation

public struct RemovableVolume: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let uuid: String?
    public let isRemovable: Bool

    public init(url: URL, name: String, uuid: String?, isRemovable: Bool) {
        self.url = url
        self.name = name
        self.uuid = uuid
        self.isRemovable = isRemovable
    }
}

/// Reads/writes the device key file on candidate volumes. Abstracted so tests
/// run without real USB hardware.
public protocol DeviceKeyProvider: Sendable {
    func candidateVolumes() -> [RemovableVolume]
    func readKey(volumeURL: URL, relPath: String) -> Data?
    func writeKey(_ key: Data, volumeURL: URL, relPath: String) throws
    func removeKey(volumeURL: URL, relPath: String)
}

extension DeviceKeyProvider {
    /// Every device key currently reachable, best candidate first.
    ///
    /// Returning all of them (rather than the first hit) matters: a second
    /// volume carrying a `.safekey/device.key` — planted, or just an old stick
    /// still lying around — would otherwise shadow the real one, and every
    /// resulting failure would be charged to the user as a wrong password,
    /// potentially driving an armed vault to self-destruct. Callers try each
    /// candidate before recording a failure.
    ///
    /// Volume UUID only orders the list; the key bytes are the security
    /// boundary, not the volume identity, so a renamed or restored stick still
    /// works.
    public func locateDeviceKeys(policy: UnlockPolicy) -> [Data] {
        guard policy.requiresDevice, let relPath = policy.keyFileRelPath else { return [] }
        let volumes = candidateVolumes()
        let preferred = volumes.filter { $0.uuid != nil && $0.uuid == policy.volumeUUID }
        let rest = volumes.filter { !($0.uuid != nil && $0.uuid == policy.volumeUUID) }

        var keys: [Data] = []
        for volume in preferred + rest {
            if let key = readKey(volumeURL: volume.url, relPath: relPath), !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    /// The single best candidate, for callers that only need presence
    /// (the unlock-screen indicator) or that already hold the right stick.
    public func locateDeviceKey(policy: UnlockPolicy) -> Data? {
        locateDeviceKeys(policy: policy).first
    }
}

/// Real implementation over mounted filesystem volumes.
public struct VolumeDeviceKeyProvider: DeviceKeyProvider {
    public static let defaultKeyRelPath = ".safekey/device.key"
    public static let deviceKeyByteCount = 32

    public init() {}

    /// `keyFileRelPath` comes from the container header, which is not
    /// authenticated at the time it is used. Left unchecked, a `../` in it
    /// would let a tampered vault make this unsandboxed app read or write an
    /// arbitrary path. Only a plain relative path under the volume root is
    /// accepted.
    static func safeURL(volumeURL: URL, relPath: String) -> URL? {
        guard !relPath.isEmpty, !relPath.hasPrefix("/") else { return nil }
        let components = relPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") , !components.contains(".") else { return nil }
        var url = volumeURL.standardizedFileURL
        for component in components {
            url.appendPathComponent(String(component))
        }
        // Belt and braces: the resolved path must still sit under the volume.
        let root = volumeURL.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        guard resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return url
    }

    public func candidateVolumes() -> [RemovableVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true
            else { return nil }
            // The boot volume is not a security key.
            if url.path == "/" { return nil }
            return RemovableVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                uuid: values.volumeUUIDString,
                isRemovable: (values.volumeIsRemovable ?? false) || !(values.volumeIsInternal ?? true)
            )
        }
    }

    public func readKey(volumeURL: URL, relPath: String) -> Data? {
        guard let url = Self.safeURL(volumeURL: volumeURL, relPath: relPath) else { return nil }
        guard let data = try? Data(contentsOf: url),
              data.count == Self.deviceKeyByteCount
        else { return nil }
        return data
    }

    public func writeKey(_ key: Data, volumeURL: URL, relPath: String) throws {
        guard let url = Self.safeURL(volumeURL: volumeURL, relPath: relPath) else {
            throw VaultError.corruptVault
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try key.write(to: url)
        // The second factor is key material: keep it owner-only where the
        // filesystem supports it (FAT sticks silently ignore this).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func removeKey(volumeURL: URL, relPath: String) {
        guard let url = Self.safeURL(volumeURL: volumeURL, relPath: relPath) else { return }
        try? FileManager.default.removeItem(at: url)
        // Remove the .safekey directory too if it is now empty.
        let dir = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
