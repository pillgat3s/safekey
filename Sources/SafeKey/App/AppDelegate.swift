import AppKit
import CloudKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A shared-group invitation the user accepted.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        MainActor.assumeIsolated {
            CloudShareInbox.shared.accept(metadata)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // State restoration would snapshot window contents (secrets) to disk.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        MainActor.assumeIsolated {
            guard !DebugSupport.runRebrandHookIfNeeded() else { return }
            guard !DebugSupport.renderChainSheetIfNeeded() else { return }
            guard !DebugSupport.runBiometricDiagnosticIfNeeded() else { return }
            guard !DebugSupport.runSharedGroupProbeIfNeeded() else { return }
            DisguiseManager.shared.applyRuntimeDisguise()
            DebugSupport.installWindowFramingIfNeeded()
            DebugSupport.captureScopeSheetIfNeeded()
            DebugSupport.dumpToolbarIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
