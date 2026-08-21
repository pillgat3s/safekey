import AppKit
import Observation

/// Two levels of disguise:
///
/// 1. **Runtime** — swap the Dock icon and window title for the current
///    session. Instant, reversible, no signing involved. Re-applied at launch
///    from UserDefaults (the choice must be readable while locked, so it
///    cannot live in the encrypted payload).
/// 2. **Rebrand** — rewrite the app bundle's display name and icon file, then
///    re-sign ad-hoc and relaunch. Survives in Finder, Dock, and Spotlight.
///
/// The bundle identifier is never touched: the Keychain items and the
/// Application Support path are keyed to it, so changing it would orphan the
/// vault.
@MainActor
@Observable
final class DisguiseManager {
    static let shared = DisguiseManager()

    private static let presetKey = "safekey.disguise.presetID"
    private static let customNameKey = "safekey.disguise.customName"

    private(set) var currentPresetID: String
    private(set) var customName: String
    private(set) var lastError: String?

    private init() {
        currentPresetID = UserDefaults.standard.string(forKey: Self.presetKey) ?? DisguisePreset.original.id
        customName = UserDefaults.standard.string(forKey: Self.customNameKey) ?? ""
    }

    var currentPreset: DisguisePreset {
        DisguisePreset.preset(id: currentPresetID) ?? .original
    }

    /// The name shown in the window title and (after a rebrand) in Finder.
    var effectiveName: String {
        customName.isEmpty ? currentPreset.displayName : customName
    }

    // MARK: - Runtime disguise

    /// Applies the stored disguise to the running app. Call at launch.
    ///
    /// There is no light/dark variant to choose between: a macOS `.appiconset`
    /// cannot carry appearance variants, and swapping only the Dock icon at
    /// runtime would leave Finder and Spotlight disagreeing with it. The single
    /// icon is designed to sit correctly on either background.
    func applyRuntimeDisguise() {
        let preset = currentPreset
        guard preset.id != DisguisePreset.original.id || !customName.isEmpty else {
            NSApp.applicationIconImage = nil // restore the bundle icon
            return
        }
        NSApp.applicationIconImage = DisguiseIconRenderer.image(for: preset, size: 512)
    }

    func select(presetID: String, customName: String) {
        currentPresetID = presetID
        self.customName = customName
        UserDefaults.standard.set(presetID, forKey: Self.presetKey)
        UserDefaults.standard.set(customName, forKey: Self.customNameKey)
        applyRuntimeDisguise()
    }

    // MARK: - Bundle rebrand

    enum RebrandError: LocalizedError {
        case notWritable
        case plistFailed
        case iconFailed
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notWritable:
                "SafeKey can't modify its own app bundle here. Move SafeKey.app to /Applications or your home folder and try again."
            case .plistFailed:
                "Could not update the app's Info.plist."
            case .iconFailed:
                "Could not write the new icon file."
            case .signingFailed(let detail):
                "Re-signing the app failed: \(detail)"
            }
        }
    }

    var bundleIsWritable: Bool {
        FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.path)
    }

    /// Whether the bundle on disk carries a disguise, as opposed to only the
    /// running app's Dock icon.
    ///
    /// Read from the loaded Info.plist, which is safe: a rebrand relaunches, so
    /// what this process started with is what is on disk.
    var bundleIsRebranded: Bool {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name != nil && name != DisguisePreset.original.displayName
    }

    /// What a rebrand costs, because the re-sign below is ad-hoc.
    ///
    /// Signing a bundle again replaces its entitlements, and an ad-hoc
    /// signature cannot carry the ones this app is granted: the Keychain access
    /// group and the iCloud container are tied to a team identity. Without them
    /// the Keychain refuses every call (errSecMissingEntitlement) and CloudKit
    /// has no container to reach — so Touch ID unlock and iCloud sync both
    /// stop, and reverting cannot bring them back, because the original
    /// signature needs a certificate this Mac is not required to have.
    /// Reinstalling the app restores both.
    static let rebrandCost = "Rebranding re-signs SafeKey, and a re-signed copy loses the permissions Apple grants it. Touch ID unlock and iCloud sync stop working until you reinstall SafeKey — reverting the disguise does not bring them back. Your vault and everything in it are untouched either way."

    /// Rewrites the bundle so Finder/Dock/Spotlight show the disguise, then
    /// relaunches. The running binary is never modified — only Info.plist and
    /// the icon resource — because rewriting the executable of a running
    /// process invites a kernel kill on page-in.
    func rebrandBundle(preset: DisguisePreset, customName: String, relaunch shouldRelaunch: Bool = true) throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleIsWritable else { throw RebrandError.notWritable }

        let name = customName.isEmpty ? preset.displayName : customName
        let contents = bundleURL.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")

        guard var plist = NSMutableDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw RebrandError.plistFailed
        }
        plist["CFBundleDisplayName"] = name
        plist["CFBundleName"] = name
        let iconFile = "AppIcon"
        plist["CFBundleIconFile"] = iconFile
        // CFBundleIdentifier is deliberately untouched (vault + Keychain paths).

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            throw RebrandError.plistFailed
        }

        let resources = contents.appendingPathComponent("Resources")
        let icnsURL = resources.appendingPathComponent("\(iconFile).icns")
        do {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try writeICNS(for: preset, to: icnsURL)
        } catch {
            throw RebrandError.iconFailed
        }

        try resign(bundleURL: bundleURL)
        select(presetID: preset.id, customName: customName)
        if shouldRelaunch {
            relaunch(bundleURL: bundleURL)
        }
    }

    /// Puts the bundle back to the name and icon it shipped with.
    ///
    /// Not `rebrandBundle(preset: .original)`: that would leave a *rendered*
    /// copy of the app icon in `Resources` and keep pointing at it. Dropping
    /// the override instead hands the icon back to the asset catalog, which is
    /// where the real one lives.
    ///
    /// What it cannot undo is the signature — see ``rebrandCost``.
    func revertBundle(relaunch shouldRelaunch: Bool = true) throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleIsWritable else { throw RebrandError.notWritable }
        let contents = bundleURL.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")

        guard var plist = NSMutableDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw RebrandError.plistFailed
        }
        let original = DisguisePreset.original.displayName
        plist["CFBundleDisplayName"] = original
        plist["CFBundleName"] = original
        plist.removeValue(forKey: "CFBundleIconFile")

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            throw RebrandError.plistFailed
        }

        let icnsURL = contents
            .appendingPathComponent("Resources")
            .appendingPathComponent("AppIcon.icns")
        try? FileManager.default.removeItem(at: icnsURL)

        try resign(bundleURL: bundleURL)
        select(presetID: DisguisePreset.original.id, customName: "")
        if shouldRelaunch {
            relaunch(bundleURL: bundleURL)
        }
    }

    // MARK: - Internals

    /// Builds a multi-resolution .icns via `iconutil` from a rendered iconset.
    private func writeICNS(for preset: DisguisePreset, to url: URL) throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safekey-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = workDir.appendingPathComponent("icon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let variants: [(name: String, size: CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for variant in variants {
            let image = DisguiseIconRenderer.image(for: preset, size: variant.size)
            guard
                let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else { continue }
            try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RebrandError.iconFailed }
    }

    /// Modifying bundle resources invalidates the signature; re-sign ad-hoc.
    private func resign(bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundleURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw RebrandError.signingFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "exit \(process.terminationStatus)"
            throw RebrandError.signingFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func relaunch(bundleURL: URL) {
        Task { @MainActor in
            // A just-re-signed bundle can lose a launch race with the
            // signature cache; one retry after a short delay covers it.
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
                    break
                } catch {
                    continue
                }
            }
            NSApp.terminate(nil)
        }
    }
}
