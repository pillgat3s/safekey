import Foundation
import AppKit
import SwiftUI
import LocalAuthentication
import Security
import SafeKeyCore

/// DEBUG-only hooks for development and UI verification. Compiled out of
/// release builds entirely.
enum DebugSupport {
    /// `SAFEKEY_ALLOW_CAPTURE=1` disables the screen-capture block so the UI
    /// can be screenshotted during development.
    static var allowsCapture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SAFEKEY_ALLOW_CAPTURE"] == "1"
        #else
        false
        #endif
    }

    /// `SAFEKEY_DEMO=1` boots into a throwaway vault (temp directory, fixed
    /// password) seeded with sample data — never touches the real vault.
    /// `SAFEKEY_DEMO_STATE=locked` starts at the unlock screen instead.
    static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SAFEKEY_DEMO"] == "1"
        #else
        false
        #endif
    }

    static var demoStartsLocked: Bool {
        ProcessInfo.processInfo.environment["SAFEKEY_DEMO_STATE"] == "locked"
    }

    static let demoPassword = "demo-password-123"

    /// `SAFEKEY_REBRAND_PRESET=<id>` (optionally with `SAFEKEY_REBRAND_NAME`)
    /// runs the bundle rebrand at launch and exits — lets the rebrand path be
    /// verified without driving the Settings UI.
    @MainActor
    static func runRebrandHookIfNeeded() -> Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let presetID = env["SAFEKEY_REBRAND_PRESET"] else { return false }
        let preset = DisguisePreset.preset(id: presetID) ?? .original
        let name = env["SAFEKEY_REBRAND_NAME"] ?? ""
        do {
            try DisguiseManager.shared.rebrandBundle(preset: preset, customName: name, relaunch: false)
            FileHandle.standardError.write(Data("[rebrand] ok: \(preset.id) as \"\(name.isEmpty ? preset.displayName : name)\"\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[rebrand] failed: \(error.localizedDescription)\n".utf8))
        }
        exit(0)
        #else
        return false
        #endif
    }

    /// `SAFEKEY_CHAIN_SHEET=/x.png` renders every chain tile through the real
    /// `ChainLogo` view and writes a contact sheet, then exits. Offscreen via
    /// `ImageRenderer`, so it needs no window server or screen-recording
    /// permission — it is how the artwork gets eyeballed after a change.
    @MainActor
    static func renderChainSheetIfNeeded() -> Bool {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["SAFEKEY_CHAIN_SHEET"] else { return false }
        let chains = Chain.catalog + [.custom("Kaspa"), .custom("Nervos Network")]
        let renderer = ImageRenderer(content: ChainContactSheet(chains: chains))
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("[chains] wrote \(png.count) bytes\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[chains] render failed\n".utf8))
        }
        exit(0)
        #else
        return false
        #endif
    }

    /// `SAFEKEY_BIO_DIAG=1` reports the biometric plumbing's real state —
    /// availability, strategy, and the exact Keychain status codes — from
    /// inside the app, where the code identity that gates Keychain access is
    /// the app's own.
    @MainActor
    static func runBiometricDiagnosticIfNeeded() -> Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SAFEKEY_BIO_DIAG"] == "1" else { return false }
        var out = "[bio] ==== biometric diagnostic ====\n"

        let context = LAContext()
        var laError: NSError?
        let can = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError)
        out += "[bio] canEvaluatePolicy(biometrics) = \(can)\n"
        if let laError { out += "[bio]   error: \(laError.domain) \(laError.code) \(laError.localizedDescription)\n" }
        out += "[bio] biometryType = \(context.biometryType.rawValue) (2 = TouchID)\n"

        var deviceOwnerError: NSError?
        let canOwner = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &deviceOwnerError)
        out += "[bio] canEvaluatePolicy(deviceOwner) = \(canOwner)\n"

        let store = VaultStore()
        if let container = try? Data(contentsOf: store.vaultURL),
           let header = try? VaultFileFormat.decode(container).header {
            let factor = BiometricFactor()
            out += "[bio] vaultID = \(header.vaultID.uuidString)\n"
            out += "[bio] marker strategy = \(factor.activeStrategy(vaultID: header.vaultID)?.rawValue ?? "none")\n"
            out += "[bio] resolved strategy = \(factor.resolvedStrategy(vaultID: header.vaultID)?.rawValue ?? "none")\n"
            out += "[bio] isEnrolled = \(factor.isEnrolled(vaultID: header.vaultID))\n"
            out += "[bio] → badge would \(factor.isEnrolled(vaultID: header.vaultID) ? "SHOW" : "be hidden")\n"

            // Can we read the real key's data silently? This is exactly what
            // pressing the badge does after the fingerprint succeeds.
            SecKeychainSetUserInteractionAllowed(false)
            let realQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.andri.safekey",
                kSecAttrAccount as String: "dek.bio.\(header.vaultID.uuidString)",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var realOut: CFTypeRef?
            let realStatus = SecItemCopyMatching(realQuery as CFDictionary, &realOut)
            SecKeychainSetUserInteractionAllowed(true)
            let bytes = (realOut as? Data)?.count ?? 0
            out += "[bio] REAL key silent read → OSStatus \(realStatus), \(bytes) bytes"
            out += realStatus == errSecSuccess ? "  ✅ WORKS\n" : "  ❌\n"

            for dataProtection in [false, true] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "com.andri.safekey",
                    kSecAttrAccount as String: "dek.bio.\(header.vaultID.uuidString)",
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
                let status = SecItemCopyMatching(query as CFDictionary, nil)
                out += "[bio] lookup dataProtection=\(dataProtection) → OSStatus \(status)\n"
            }
        } else {
            out += "[bio] no readable vault header\n"
        }

        // Round-trip a throwaway item to prove whether this app can use the
        // Keychain at all under its current signature.
        let probe = KeychainService(service: "com.andri.safekey.probe")
        do {
            try probe.write(Data([1, 2, 3]), account: "probe", accessibility: .whenUnlockedThisDeviceOnly)
            let read = try probe.read(account: "probe")
            out += "[bio] plain keychain write+read = \(read == Data([1, 2, 3]) ? "OK" : "MISMATCH")\n"
            try probe.delete(account: "probe")
            out += "[bio] plain keychain delete = OK\n"
        } catch {
            out += "[bio] plain keychain round-trip FAILED: \(error)\n"
        }

        // The whole enrol path against a throwaway vault ID. `confirm: false`
        // so the diagnostic does not raise a Touch ID prompt.
        Task { @MainActor in
            var out = out
            let testVault = UUID()
            let factor = BiometricFactor()
            do {
                let strategy = try await factor.enable(
                    secret: Data(repeating: 7, count: 32),
                    vaultID: testVault,
                    confirm: false
                )
                out += "[bio] enable(test) → strategy \(strategy.rawValue)\n"
                out += "[bio] isEnrolled(test) = \(factor.isEnrolled(vaultID: testVault))\n"
            } catch {
                out += "[bio] enable(test) FAILED: \(error)\n"
            }
            // The decisive question: can this app read the item's *data*
            // without macOS raising the login-keychain ACL prompt? Interaction
            // is switched off, so errSecInteractionNotAllowed means "would have
            // prompted" and errSecSuccess means the ACL is satisfied.
            SecKeychainSetUserInteractionAllowed(false)
            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.andri.safekey",
                kSecAttrAccount as String: "dek.bio.\(testVault.uuidString)",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var dataOut: CFTypeRef?
            let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataOut)
            SecKeychainSetUserInteractionAllowed(true)
            out += "[bio] silent DATA read of fresh item → OSStatus \(dataStatus)"
            out += dataStatus == errSecSuccess ? "  (no prompt — ACL OK)\n" : "  (WOULD PROMPT)\n"

            try? factor.disable(vaultID: testVault)
            factor.forgetStrategyMarker(vaultID: testVault)

            FileHandle.standardError.write(Data(out.utf8))
            exit(0)
        }
        return true
        #else
        return false
        #endif
    }

    /// `SAFEKEY_UNLOCK_SHEET=/x.png` renders the lock screen offscreen and
    /// exits, so its layout can be reviewed without a screen capture.
    @MainActor
    static func renderUnlockSheetIfNeeded(model: AppModel) -> Bool {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["SAFEKEY_UNLOCK_SHEET"] else { return false }
        let renderer = ImageRenderer(content: UnlockPreviewSheet().environment(model))
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("[unlock] wrote \(png.count) bytes\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[unlock] render failed\n".utf8))
        }
        exit(0)
        #else
        return false
        #endif
    }

    /// `SAFEKEY_TOOLBAR_DUMP=1` shrinks the window to its minimum and prints
    /// the frame of every titlebar control, so alignment can be measured
    /// instead of eyeballed.
    @MainActor
    static func dumpToolbarIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SAFEKEY_TOOLBAR_DUMP"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            // Collapse to the smallest size the layout permits.
            window.setFrame(NSRect(x: 60, y: 60, width: 200, height: 200), display: true)
            try? await Task.sleep(for: .milliseconds(700))

            var out = "[toolbar] window \(Int(window.frame.width))×\(Int(window.frame.height))\n"
            func walk(_ view: NSView, depth: Int) {
                let name = String(describing: type(of: view))
                let inWindow = view.convert(view.bounds, to: nil)
                // Titlebar controls only.
                if inWindow.maxY > window.frame.height - 60, inWindow.height > 4, inWindow.width > 4 {
                    let interesting = name.contains("Button") || name.contains("Search")
                        || name.contains("Field") || name.contains("Toolbar") || name.contains("Item")
                    if interesting {
                        out += String(
                            format: "  %@%@  x=%.1f y=%.1f w=%.1f h=%.1f midY=%.1f\n",
                            String(repeating: " ", count: depth), name,
                            inWindow.minX, inWindow.minY, inWindow.width, inWindow.height, inWindow.midY
                        )
                    }
                }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            if let frameView = window.contentView?.superview {
                walk(frameView, depth: 0)
            }
            FileHandle.standardError.write(Data(out.utf8))
            exit(0)
        }
        #endif
    }

    /// `SAFEKEY_WINDOW_FRAME=1` sizes and fronts the main window
    /// deterministically after launch, so screenshots taken by the UI test
    /// bundle (or by hand) are comparable run to run.
    @MainActor
    static func installWindowFramingIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SAFEKEY_WINDOW_FRAME"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            window.setFrame(NSRect(x: 100, y: 100, width: 1240, height: 780), display: true)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        #endif
    }

    static func demoStore() -> VaultStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeyDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        return VaultStore(directory: dir)
    }

    /// The same invented wallets the iPhone's `--promo` vault shows, so the two
    /// apps agree on screen when they are filmed side by side.
    static func demoPayload() -> VaultPayload {
        #if DEBUG
        PromoContent.payload()
        #else
        VaultPayload()
        #endif
    }
}
