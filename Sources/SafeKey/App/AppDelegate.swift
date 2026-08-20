import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // State restoration would snapshot window contents (secrets) to disk.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        MainActor.assumeIsolated {
            guard !DebugSupport.runRebrandHookIfNeeded() else { return }
            guard !DebugSupport.renderChainSheetIfNeeded() else { return }
            guard !DebugSupport.runBiometricDiagnosticIfNeeded() else { return }
            DisguiseManager.shared.applyRuntimeDisguise()
            DebugSupport.installWindowFramingIfNeeded()
            DebugSupport.dumpToolbarIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
